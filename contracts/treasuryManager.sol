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

/*
The treasury manager can be used by a protocol to deploy assets to a single asset vault ie. Yearn / Robo Vault. A target APR can be set within the vault
Each EPOCH any excess yield earned above the target APR can be used to purchase a "Target Token" for the treasury 
*/


contract treasuryManager is Ownable, ReentrancyGuard  {


    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    IERC20 public base;
    IERC20 public targetToken;
    uint256 constant BPS_adj = 1000000;
    uint256 public targetAPR;
    address public vaultAddress;
    address public strategist;
    address public treasury;
    address public router;
    address public weth; 
    uint256 timePerEpoch = 43200;
    uint256 constant yearAdj = 31557600;
    uint256 lastEpoch;
    uint256 public epoch = 0; 
    uint256 public epochDeposits = 0;
    uint256 public epochWithdrawals = 0;
    uint256 public balanceTracker = 0;


    constructor(
        address _base,
        address _targetToken,
        address _vault,
        address _router,
        address _weth,
        address _treasury,
        address _strategist,
        uint256 _targetAPR

    ) public {
        base = IERC20(_base);
        targetToken = IERC20(_targetToken);
        vaultAddress = _vault;
        router = _router;
        lastEpoch = block.timestamp;
        base.approve(vaultAddress, uint(-1));
        base.approve(router, uint(-1));
        weth = _weth;
        treasury = _treasury;
        targetAPR = _targetAPR;

    }


    modifier onlyApproved() {
        require(owner() == msg.sender || strategist == msg.sender , "Approve: caller is not approved");
        _;
    }    

    function deposit(uint256 _amount) external onlyOwner
    {
      require(_amount > 0, "deposit must be greater than 0");    
      base.transferFrom(treasury, address(this), _amount);
      epochDeposits = epochDeposits.add(_amount);
    }


    function withdraw(uint256 _amount) external onlyOwner
    {
      //require(_shares > 0, "withdraw must be greater than 0");
      base.safeTransfer(treasury, _amount);
      epochWithdrawals = epochWithdrawals.add(_amount);

    }
    
    function balanceBase() public view returns(uint256) {
        uint256 bal = base.balanceOf(address(this));
        IERC20 vaultToken = IERC20(vaultAddress);
        uint256 vaultBPS = 1000000000000000000; /// TO DO UPDATE THIS TO READ FROM VAULT 
        uint256 vaultBalance = vaultToken.balanceOf(address(this)).mul(vault(vaultAddress).pricePerShare()).div(vaultBPS);

        bal = bal.add(vaultBalance);
        
        return(bal);
    }

    function vaultBalance() internal view returns(uint256) {
        uint256 bal = vault(vaultAddress).balanceOf(address(this));
        return(bal);
    }

    function depositToVault() external onlyApproved {
        _depositToVault();
    }

    function _depositToVault() internal {
        uint256 bal = base.balanceOf(address(this));
        vault(vaultAddress).deposit(bal);
    }

    function withdrawFromVault() external onlyApproved {
        _withdrawFromVault();
    }

    function _withdrawFromVault() internal {
        vault(vaultAddress).withdraw();
    }

    function updateVault(address _newVault) external onlyApproved {
        _withdrawFromVault();
        vaultAddress = _newVault;
        base.approve(vaultAddress, uint(-1));   
        _depositToVault();     
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

    // this function will take any yield above target APR level for the EPOCH and buy TargetToken and then transfer to treasury 
    function convertProfits() external onlyApproved {
        require(block.timestamp >= lastEpoch.add(timePerEpoch)); // can only convert profits once per EPOCH 
        uint256 timeSinceEpoch = block.timestamp.sub(lastEpoch);
        
        /// TO DO -> this is potentially somewhat inefficient to withdraw 100% of funds from vault although gives accurate accounting of balance 
        _withdrawFromVault();
        uint256 expectedYield = balanceTracker.mul(targetAPR).mul(timeSinceEpoch).div(BPS_adj).div(yearAdj);
        uint256 expectedBalance = expectedYield.add(balanceTracker).add(epochDeposits).sub(epochWithdrawals);
        if (balanceBase() > expectedBalance) {
            uint256 profits = balanceBase().sub(expectedBalance); // 
            uint256 amountOutMin = 0; // TO DO FIX THIS SO WEE DON"T GET FRONT RUN
            address[] memory path = getTokenOutPath(address(base), address(targetToken));
            uint256 preSwapBalance = targetToken.balanceOf(address(this));
            IUniswapV2Router01(router).swapExactTokensForTokens(profits, amountOutMin, path, treasury, now);
        }
        balanceTracker = balanceBase();
        epochDeposits = 0;
        epochWithdrawals = 0;
        _depositToVault();
        epoch = epoch.add(1);
        lastEpoch = block.timestamp;
        
    }

}