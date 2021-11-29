// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;

interface vault {
    function deposit(uint256 amount) external;
    function withdraw() external; 
    function withdrawAll() external; 
    function pricePerShare() external view returns (uint256);  
    function balanceOf(address _address) external view returns (uint256);
    function want() external view returns(address);
}