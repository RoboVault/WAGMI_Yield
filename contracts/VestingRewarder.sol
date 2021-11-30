// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/uniswap.sol";
import "../interfaces/vaults.sol";
import "../interfaces/IStrategy.sol";


/**
This builds on the vaultContainer with a further simplification and change
Instead of acting as a proxy to vaults
The use case is to act as a staking rewards contract
Users stake yTokens
Strat sends us want tokens when harvested and epoch is flipped
Want tokens are sold to targetTokens
Users maay then claim their tokenss
 */

/*
The vault container essentially allows users to deposit funds which are then deployed to a single asset vault i.e YEARN / ROBOVAULT 
at each EPOCH any yield / profit generate from the strategy is then used to purchase the TARGET Token of the users choice 
For example this would give users the ability to deposit into a USDC vault while their USDC balance will remain the same extra USDC could be used to buy 
a target token such as OHM 

Additionally some mechanics on vesting of the target tokens are built in encouraging users to keep their assets in the vault container over a longer period
*/

contract VestingRewards is Ownable, ERC20, ReentrancyGuard  {

    struct UserInfo {
        uint256 amount;     // How many tokens the user has provided.
        uint256 epochStart; // at what Epoch will rewards start 
        uint256 depositTime; // when did the user deposit 
    }

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 public base;
    IERC20 public want; // want token we recv from the strat
    IERC20 public targetToken;

    uint256 constant BPS_adj = 10000;
    address public router;
    address public weth; 
    uint256 timePerEpoch = 0; /// set to 0 for testing 
    uint256 public vestingTime = 432000;
    uint256 lastEpoch;
    uint256 public unvestedTokens = 0; 
    uint256 public epoch = 0; 
    mapping (address => UserInfo) public userInfo;
    mapping (uint256 => uint256) public epochRewards;
    mapping (uint256 => uint256) public epochBalance; 
    IStrategy public underlyingStrategy;
    address public keeper;

    constructor(
        string memory _name, 
        string memory _symbol,
        address _base,
        address _want,
        address _targetToken,
        address _router,
        address _weth,
        address _underlyingStrategy
    ) public ERC20(_name, _symbol) {
        base = IERC20(_base);
        targetToken = IERC20(_targetToken);
        router = _router;
        lastEpoch = block.timestamp;
        want = IERC20(_want);
        want.approve(router, uint(-1));
        weth = _weth;
        underlyingStrategy = IStrategy(underlyingStrategy);
    }

    modifier onlyAuthorized() {
        require(msg.sender == keeper || msg.sender == owner(), "!authorized");
        _;
    }

    function setKeeper(address _keeper) external onlyAuthorized {
        require(_keeper != address(0));
        keeper = _keeper;
    }

    // user deposits token to vault container in exchange for pool shares which can later be redeemed for assets + accumulated yield
    function deposit(uint256 _amount) public nonReentrant
    {
      require(_amount > 0, "deposit must be greater than 0");
      uint256 pool = totalSupply();

      if (balanceOf(msg.sender) > 0) {
          _disburseRewards(msg.sender);
      }
    
      base.transferFrom(msg.sender, address(this), _amount);
    
      // Calculate pool shares
      uint256 shares = 0;
      if (totalSupply() == 0) {
        shares = _amount;
      } else {
        shares = (_amount.mul(totalSupply())).div(pool);
      }
      _mint(msg.sender, shares);

      userInfo[msg.sender] = UserInfo(balanceOf(msg.sender), epoch, block.timestamp);
    }

    function depositAll() public {
        uint256 balance = base.balanceOf(msg.sender); 
        deposit(balance); 
    }

    // No rebalance implementation for lower fees and faster swaps
    function withdraw(uint256 _shares) public nonReentrant
    {
      require(_shares > 0, "withdraw must be greater than 0");
      
      uint256 ibalance = balanceOf(msg.sender);
      require(_shares <= ibalance, "insufficient balance");
      uint256 pool = totalSupply();
      // Calc to redeem before updating balances
      uint256 r = (pool.mul(_shares)).div(totalSupply());
      _burn(msg.sender, _shares);
    
      // Check balance
      uint256 b = base.balanceOf(address(this));
      base.safeTransfer(msg.sender, r);
      _disburseRewards(msg.sender);

      userInfo[msg.sender] = UserInfo(balanceOf(msg.sender), epoch, block.timestamp);
    }

    function withdrawAll() public {
        uint256 ibalance = balanceOf(msg.sender);
        withdraw(ibalance);
    }

    function getTokenOutPath(address _token_in, address _token_out)
        internal
        view
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == address(weth) || _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;
        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function harvest() public onlyAuthorized {
        // harvest to get tokens then swap tokens
        underlyingStrategy.harvest(); // this will get us the profits
        convertProfits();
    }

    function convertProfits() public onlyAuthorized {
        uint256 amountOutMin = 0; // TO DO make sure don't get front run 
        uint256 profits = want.balanceOf(address(this));
        address[] memory path = getTokenOutPath(address(want), address(targetToken));
        uint256 preSwapBalance = targetToken.balanceOf(address(this));
        if (profits > 0){
            IUniswapV2Router01(router).swapExactTokensForTokens(profits, amountOutMin, path, address(this), block.timestamp + 100);
        }

        epochRewards[epoch] = (targetToken.balanceOf(address(this)).sub(preSwapBalance)).add(unvestedTokens); 
        epochBalance[epoch] = totalSupply();
        epoch = epoch.add(1);
        lastEpoch = block.timestamp;
        unvestedTokens = 0;
    }

    function _disburseRewards(address _user) internal {
        uint256 rewards = getUserRewards(_user);
        uint256 vestedRewards = rewards.mul(getVestingPercent(_user)).div(BPS_adj);
        uint256 userUnvested = rewards.sub(vestedRewards);
        unvestedTokens = unvestedTokens.add(userUnvested);
        targetToken.transfer(_user, rewards);
    }

    function getVestingPercent(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 vestPercent = ((block.timestamp).sub(user.depositTime)).mul(BPS_adj).div(vestingTime);
        if (vestPercent > BPS_adj){
            vestPercent = BPS_adj;
        }
        return(vestPercent);
    }


    function getUserRewards(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 rewardStart = user.epochStart;
        uint256 rewards = 0;
        uint256 userRewards;
        require(epoch > rewardStart);
        for (uint i=rewardStart; i<epoch; i++) {
            userRewards = epochRewards[i].mul(user.amount).div(epochBalance[i]); // this should give user rewards in native token
            rewards = rewards.add(userRewards);
        }

        return(rewards);      
    }
}
