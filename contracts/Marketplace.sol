// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./Configuration.sol";
import "./Requests.sol";
import "./Collateral.sol";
import "./Proofs.sol";
import "./StateRetrieval.sol";

contract Marketplace is Collateral, Proofs, StateRetrieval {
  using EnumerableSet for EnumerableSet.Bytes32Set;
  using Requests for Request;

  MarketplaceConfig public config;

  MarketplaceFunds private _funds;
  mapping(RequestId => Request) private _requests;
  mapping(RequestId => RequestContext) private _requestContexts;
  mapping(SlotId => Slot) private _slots;

  struct RequestContext {
    RequestState state;
    uint256 slotsFilled;
    uint256 startedAt;
    uint256 endsAt;
  }

  struct Slot {
    SlotState state;
    RequestId requestId;
    address host;
  }

  constructor(
    IERC20 token,
    MarketplaceConfig memory configuration
  ) Collateral(token) Proofs(configuration.proofs) marketplaceInvariant {
    config = configuration;
  }

  function _isWithdrawAllowed() internal view override returns (bool) {
    return !_hasSlots(msg.sender);
  }

  function requestStorage(
    Request calldata request
  ) public marketplaceInvariant {
    require(request.client == msg.sender, "Invalid client address");

    RequestId id = request.id();
    require(_requests[id].client == address(0), "Request already exists");

    _requests[id] = request;
    _requestContexts[id].endsAt = block.timestamp + request.ask.duration;

    _addToMyRequests(request.client, id);

    uint256 amount = request.price();
    _funds.received += amount;
    _funds.balance += amount;
    _transferFrom(msg.sender, amount);

    emit StorageRequested(id, request.ask);
  }

  function fillSlot(
    RequestId requestId,
    uint256 slotIndex,
    bytes calldata proof
  ) public requestIsKnown(requestId) {
    Request storage request = _requests[requestId];
    require(slotIndex < request.ask.slots, "Invalid slot");

    SlotId slotId = Requests.slotId(requestId, slotIndex);
    Slot storage slot = _slots[slotId];
    slot.requestId = requestId;

    require(slotState(slotId) == SlotState.Free, "Slot is not free");

    require(
      balanceOf(msg.sender) >= config.collateral.initialAmount,
      "Insufficient collateral"
    );

    _startRequiringProofs(slotId, request.ask.proofProbability);
    submitProof(slotId, proof);

    slot.host = msg.sender;
    slot.state = SlotState.Filled;
    RequestContext storage context = _requestContexts[requestId];
    context.slotsFilled += 1;

    _addToMySlots(slot.host, slotId);

    emit SlotFilled(requestId, slotIndex, slotId);
    if (context.slotsFilled == request.ask.slots) {
      context.state = RequestState.Started;
      context.startedAt = block.timestamp;
      emit RequestFulfilled(requestId);
    }
  }

  function freeSlot(SlotId slotId) public slotIsNotFree(slotId) {
    Slot storage slot = _slots[slotId];
    require(slot.host == msg.sender, "Slot filled by other host");
    SlotState state = slotState(slotId);
    require(state != SlotState.Paid, "Already paid");
    if (state == SlotState.Finished) {
      _payoutSlot(slot.requestId, slotId);
    } else if (state == SlotState.Failed) {
      _removeFromMySlots(msg.sender, slotId);
    } else if (state == SlotState.Filled) {
      _forciblyFreeSlot(slotId);
    }
  }

  function markProofAsMissing(SlotId slotId, Period period) public {
    require(slotState(slotId) == SlotState.Filled, "Slot not accepting proofs");
    _markProofAsMissing(slotId, period);
    address host = getHost(slotId);
    if (missingProofs(slotId) % config.collateral.slashCriterion == 0) {
      _slash(host, config.collateral.slashPercentage);

      if (balanceOf(host) < config.collateral.minimumAmount) {
        // When the collateral drops below the minimum threshold, the slot
        // needs to be freed so that there is enough remaining collateral to be
        // distributed for repairs and rewards (with any leftover to be burnt).
        _forciblyFreeSlot(slotId);
      }
    }
  }

  function _forciblyFreeSlot(SlotId slotId) internal marketplaceInvariant {
    Slot storage slot = _slots[slotId];
    RequestId requestId = slot.requestId;
    RequestContext storage context = _requestContexts[requestId];

    // TODO: burn host's slot collateral except for repair costs + mark proof
    // missing reward
    // Slot collateral is not yet implemented as the design decision was
    // not finalised.

    _removeFromMySlots(slot.host, slotId);

    slot.state = SlotState.Free;
    slot.host = address(0);
    slot.requestId = RequestId.wrap(0);
    context.slotsFilled -= 1;
    emit SlotFreed(requestId, slotId);

    Request storage request = _requests[requestId];
    uint256 slotsLost = request.ask.slots - context.slotsFilled;
    if (
      slotsLost > request.ask.maxSlotLoss &&
      context.state == RequestState.Started
    ) {
      context.state = RequestState.Failed;
      context.endsAt = block.timestamp - 1;
      emit RequestFailed(requestId);

      // TODO: burn all remaining slot collateral (note: slot collateral not
      // yet implemented)
      // TODO: send client remaining funds
    }
  }

  function _payoutSlot(
    RequestId requestId,
    SlotId slotId
  ) private requestIsKnown(requestId) marketplaceInvariant {
    RequestContext storage context = _requestContexts[requestId];
    Request storage request = _requests[requestId];
    context.state = RequestState.Finished;
    _removeFromMyRequests(request.client, requestId);
    Slot storage slot = _slots[slotId];

    _removeFromMySlots(slot.host, slotId);

    uint256 amount = _requests[requestId].pricePerSlot();
    _funds.sent += amount;
    _funds.balance -= amount;
    slot.state = SlotState.Paid;
    require(token.transfer(slot.host, amount), "Payment failed");
  }

  /// @notice Withdraws storage request funds back to the client that deposited them.
  /// @dev Request must be expired, must be in RequestState.New, and the transaction must originate from the depositer address.
  /// @param requestId the id of the request
  function withdrawFunds(RequestId requestId) public marketplaceInvariant {
    Request storage request = _requests[requestId];
    require(block.timestamp > request.expiry, "Request not yet timed out");
    require(request.client == msg.sender, "Invalid client address");
    RequestContext storage context = _requestContexts[requestId];
    require(context.state == RequestState.New, "Invalid state");

    // Update request state to Cancelled. Handle in the withdraw transaction
    // as there needs to be someone to pay for the gas to update the state
    context.state = RequestState.Cancelled;
    _removeFromMyRequests(request.client, requestId);

    emit RequestCancelled(requestId);

    // TODO: To be changed once we start paying out hosts for the time they
    // fill a slot. The amount that we paid to hosts will then have to be
    // deducted from the price.
    uint256 amount = request.price();
    _funds.sent += amount;
    _funds.balance -= amount;
    require(token.transfer(msg.sender, amount), "Withdraw failed");
  }

  function getHost(SlotId slotId) public view returns (address) {
    return _slots[slotId].host;
  }

  function getRequestFromSlotId(SlotId slotId)
    public
    view
    slotIsNotFree(slotId)
    returns (Request memory)
  {
    Slot storage slot = _slots[slotId];
    return _requests[slot.requestId];
  }

  modifier requestIsKnown(RequestId requestId) {
    require(_requests[requestId].client != address(0), "Unknown request");
    _;
  }

  function getRequest(
    RequestId requestId
  ) public view requestIsKnown(requestId) returns (Request memory) {
    return _requests[requestId];
  }

  modifier slotIsNotFree(SlotId slotId) {
    require(_slots[slotId].state != SlotState.Free, "Slot is free");
    _;
  }

  function requestEnd(RequestId requestId) public view returns (uint256) {
    uint256 end = _requestContexts[requestId].endsAt;
    RequestState state = requestState(requestId);
    if (state == RequestState.New || state == RequestState.Started) {
      return end;
    } else {
      return Math.min(end, block.timestamp - 1);
    }
  }

  function requestState(
    RequestId requestId
  ) public view requestIsKnown(requestId) returns (RequestState) {
    RequestContext storage context = _requestContexts[requestId];
    if (
      context.state == RequestState.New &&
      block.timestamp > _requests[requestId].expiry
    ) {
      return RequestState.Cancelled;
    } else if (
      context.state == RequestState.Started && block.timestamp > context.endsAt
    ) {
      return RequestState.Finished;
    } else {
      return context.state;
    }
  }

  function slotState(SlotId slotId) public view override returns (SlotState) {
    Slot storage slot = _slots[slotId];
    if (RequestId.unwrap(slot.requestId) == 0) {
      return SlotState.Free;
    }
    RequestState reqState = requestState(slot.requestId);
    if (slot.state == SlotState.Paid) {
      return SlotState.Paid;
    }
    if (reqState == RequestState.Cancelled) {
      return SlotState.Finished;
    }
    if (reqState == RequestState.Finished) {
      return SlotState.Finished;
    }
    if (reqState == RequestState.Failed) {
      return SlotState.Failed;
    }
    return slot.state;
  }

  event StorageRequested(RequestId requestId, Ask ask);
  event RequestFulfilled(RequestId indexed requestId);
  event RequestFailed(RequestId indexed requestId);
  event SlotFilled(
    RequestId indexed requestId,
    uint256 indexed slotIndex,
    SlotId slotId
  );
  event SlotFreed(RequestId indexed requestId, SlotId slotId);
  event RequestCancelled(RequestId indexed requestId);

  modifier marketplaceInvariant() {
    MarketplaceFunds memory oldFunds = _funds;
    _;
    assert(_funds.received >= oldFunds.received);
    assert(_funds.sent >= oldFunds.sent);
    assert(_funds.received == _funds.balance + _funds.sent);
  }

  struct MarketplaceFunds {
    uint256 balance;
    uint256 received;
    uint256 sent;
  }
}
