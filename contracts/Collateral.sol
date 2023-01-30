// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract Collateral {
  IERC20 public immutable token;
  CollateralTotals internal _collateralTotals;

  mapping(address => uint256) private _balances;

  constructor(IERC20 token_) {
    token = token_;
  }

  function balanceOf(address account) public view returns (uint256) {
    return _balances[account];
  }

  function _transferFrom(address sender, uint256 amount) internal {
    address receiver = address(this);
    require(token.transferFrom(sender, receiver, amount), "Transfer failed");
  }

  function deposit(uint256 amount) public {
    _transferFrom(msg.sender, amount);
    _collateralTotals.deposited += amount;
    _balances[msg.sender] += amount;
  }

  function _isWithdrawAllowed() internal virtual returns (bool);

  function withdraw() public {
    require(_isWithdrawAllowed(), "Account locked");
    uint256 amount = balanceOf(msg.sender);
    _collateralTotals.withdrawn += amount;
    _balances[msg.sender] -= amount;
    require(token.transfer(msg.sender, amount), "Transfer failed");
  }

  function _slash(address account, uint256 percentage) internal {
    uint256 amount = (balanceOf(account) * percentage) / 100;
    _collateralTotals.slashed += amount;
    _balances[account] -= amount;
  }

  struct CollateralTotals {
    uint256 deposited;
    uint256 withdrawn;
    uint256 slashed;
  }
}
