// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./TestToken.sol";
import "./Collateral.sol";

contract FuzzCollateral is Collateral {
  // solhint-disable-next-line no-empty-blocks
  constructor() Collateral(new TestToken()) {}

  // Allow fuzzing to slash an account

  function slash(address account, uint256 percentage) public {
    _slash(account, percentage);
  }

  // Allow fuzzing to change whether withdrawal is allowed

  mapping(address => bool) private _withdrawAllowed;

  function setWithdrawAllowed(address account, bool allowed) public {
    _withdrawAllowed[account] = allowed;
  }

  function _isWithdrawAllowed() internal view override returns (bool) {
    return _withdrawAllowed[msg.sender];
  }

  // Properties to be tested through fuzzing

  CollateralTotals private _lastSeenTotals;

  function neverDecreaseTotals() public {
    assert(_collateralTotals.deposited >= _lastSeenTotals.deposited);
    assert(_collateralTotals.withdrawn >= _lastSeenTotals.withdrawn);
    assert(_collateralTotals.slashed >= _lastSeenTotals.slashed);
    _lastSeenTotals = _collateralTotals;
  }

  function neverLoseFunds() public view {
    uint256 total = _collateralTotals.deposited - _collateralTotals.withdrawn;
    assert(token.balanceOf(address(this)) >= total);
  }

  function neverMoveSlashedFundsOut() public view {
    uint256 balance = token.balanceOf(address(this));
    assert(balance >= _collateralTotals.slashed);
  }

  function neverLetIndividualBalanceBeMoreThanAvailableFunds() public view {
    uint256 balance = token.balanceOf(address(this));
    uint256 available = balance - _collateralTotals.slashed;
    assert(balanceOf(msg.sender) <= available);
  }
}
