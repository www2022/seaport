// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { OrderType } from "./ConsiderationEnums.sol";

import {
    OrderParameters,
    Order,
    AdvancedOrder,
    OrderComponents,
    OrderStatus,
    CriteriaResolver
} from "./ConsiderationStructs.sol";

import "./ConsiderationConstants.sol";

import { Executor } from "./Executor.sol";

import { ZoneInteraction } from "./ZoneInteraction.sol";

/**
 * @title OrderValidator
 * @author 0age
 * @notice OrderValidator contains functionality related to validating orders
 *         and updating their status.
 */
contract OrderValidator is Executor, ZoneInteraction {
    // Track status of each order (validated, cancelled, and fraction filled).
    mapping(bytes32 => OrderStatus) private _orderStatus; // 键：orderHash（对应的结构体有很多种，比如OrderComponents、BasicOrderParameters）

    /**
     * @dev Derive and set hashes, reference chainId, and associated domain
     *      separator during deployment.
     *
     * @param conduitController A contract that deploys conduits, or proxies
     *                          that may optionally be used to transfer approved
     *                          ERC20/721/1155 tokens.
     */
    constructor(address conduitController) Executor(conduitController) {}

    /**
     * @dev Internal function to verify and update the status of a basic order.
     *
     * @param orderHash The hash of the order.
     * @param offerer   The offerer of the order.
     * @param signature A signature from the offerer indicating that the order
     *                  has been approved.
     * 验证订单是否可以被完整接单，如果不能则revert；如果可以接单、则修改orderStatus中的分子、分母-》“已完成”
     */
    function _validateBasicOrderAndUpdateStatus(
        bytes32 orderHash,
        address offerer,
        bytes memory signature
    ) internal {
        // Retrieve the order status for the given order hash.
        OrderStatus storage orderStatus = _orderStatus[orderHash];

        // Ensure order is fillable and is not cancelled.
        _verifyOrderStatus(
            orderHash,
            orderStatus,
            true, // Only allow unused orders when fulfilling basic orders.
            true // Signifies to revert if the order is invalid.
        );

        // If the order is not already validated, verify the supplied signature.
        if (!orderStatus.isValidated) {
            _verifySignature(offerer, orderHash, signature);
        }

        // Update order status as fully filled, packing struct values.
        orderStatus.isValidated = true;
        orderStatus.isCancelled = false;
        orderStatus.numerator = 1;
        orderStatus.denominator = 1; // 1/1表示订单已完成
    }

    /**
     * @dev Internal function to validate an order, determine what portion to
     *      fill, and update its status. The desired fill amount is supplied as
     *      a fraction, as is the returned amount to fill.
     *
     * @param advancedOrder     The order to fulfill as well as the fraction to
     *                          fill. Note that all offer and consideration
     *                          amounts must divide with no remainder in order
     *                          for a partial fill to be valid.
     * @param criteriaResolvers An array where each element contains a reference
     *                          to a specific offer or consideration, a token
     *                          identifier, and a proof that the supplied token
     *                          identifier is contained in the order's merkle
     *                          root. Note that a criteria of zero indicates
     *                          that any (transferable) token identifier is
     *                          valid and that no proof needs to be supplied.
     * @param revertOnInvalid   A boolean indicating whether to revert if the
     *                          order is invalid due to the time or status.
     * @param priorOrderHashes  The order hashes of each order supplied prior to
     *                          the current order as part of a "match" variety
     *                          of order fulfillment (e.g. this array will be
     *                          empty for single or "fulfill available").  // 调用zone合约的isValidOrderIncludingExtraData时会使用到
     *
     * @return orderHash      The order hash.
     * @return newNumerator   A value indicating the portion of the order that
     *                        will be filled.
     * @return newDenominator A value indicating the total size of the order.
     作用：验证订单各参数是否有效、若无效则return或revert；验证通过后，对于orderHash指定的订单，计算本次实际能够接单的份额并累加到orderStatus中已完成份额：newNumerator/newDenominator
     */
    function _validateOrderAndUpdateStatus(
        AdvancedOrder memory advancedOrder,
        CriteriaResolver[] memory criteriaResolvers,
        bool revertOnInvalid,
        bytes32[] memory priorOrderHashes // 调用zone合约的isValidOrderIncludingExtraData时会使用到
    )
        internal
        returns (
            bytes32 orderHash,
            uint256 newNumerator,
            uint256 newDenominator
        )
    {
        // Retrieve the parameters for the order.
        OrderParameters memory orderParameters = advancedOrder.parameters;

        // Ensure current timestamp falls between order start time and end time.
        if (
            !_verifyTime(
                orderParameters.startTime,
                orderParameters.endTime,
                revertOnInvalid
            )
        ) {
            // Assuming an invalid time and no revert, return zeroed out values.
            return (bytes32(0), 0, 0);
        }

        // Read numerator and denominator from memory and place on the stack.
        uint256 numerator = uint256(advancedOrder.numerator);
        uint256 denominator = uint256(advancedOrder.denominator);

        // Ensure that the supplied numerator and denominator are valid.
        if (numerator > denominator || numerator == 0) {
            revert BadFraction();
        }

        // If attempting partial fill (n < d) check order type & ensure support.
        if (
            numerator < denominator &&
            _doesNotSupportPartialFills(orderParameters.orderType)
        ) {
            // Revert if partial fill was attempted on an unsupported order.
            revert PartialFillsNotEnabledForOrder();
        }

        // Retrieve current counter & use it w/ parameters to derive order hash.
        orderHash = _assertConsiderationLengthAndGetOrderHash(orderParameters);

        // Ensure restricted orders have a valid submitter or pass a zone check.
        _assertRestrictedAdvancedOrderValidity( //验证msg.sender是否可以接单，如果不能直接revert
            advancedOrder,
            criteriaResolvers,
            priorOrderHashes, // 调用zone合约的isValidOrderIncludingExtraData时会使用到
            orderHash,
            orderParameters.zoneHash,
            orderParameters.orderType,
            orderParameters.offerer,
            orderParameters.zone
        );

        // Retrieve the order status using the derived order hash.
        OrderStatus storage orderStatus = _orderStatus[orderHash];

        // Ensure order is fillable and is not cancelled.
        if (
            !_verifyOrderStatus(
                orderHash,
                orderStatus,
                false, // Allow partially used orders to be filled.
                revertOnInvalid
            )
        ) {
            // Assuming an invalid order status and no revert, return zero fill.
            return (orderHash, 0, 0);
        }

        // If the order is not already validated, verify the supplied signature.
        if (!orderStatus.isValidated) {
            _verifySignature(
                orderParameters.offerer,
                orderHash,
                advancedOrder.signature
            );
        }

        // Read filled amount as numerator and denominator and put on the stack.
        uint256 filledNumerator = orderStatus.numerator; //uint120--》uint256
        uint256 filledDenominator = orderStatus.denominator;

        // If order (orderStatus) currently has a non-zero denominator it is
        // partially filled.
        if (filledDenominator != 0) {
            // 该订单之前被其他人部分接单过
            // If denominator of 1 supplied, fill all remaining amount on order.
            if (denominator == 1) {
                // Scale numerator & denominator to match current denominator. 等比例缩放
                numerator = filledDenominator;
                denominator = filledDenominator;
            }
            // Otherwise, if supplied denominator differs from current one...
            else if (filledDenominator != denominator) {
                // scale current numerator by the supplied denominator, then...
                filledNumerator *= denominator;

                // the supplied numerator & denominator by current denominator.
                numerator *= filledDenominator;
                denominator *= filledDenominator;
            }
            // 200～213行if-else if语句的目的：将denominator和filledNumerator缩放为相同值，接下来就只需要比较分子值。
            //
            // Once adjusted, if current+supplied numerator exceeds denominator:
            if (filledNumerator + numerator > denominator) {
                //numerator如果超过最大可接单值，则减小为最大剩余可接单值
                // Skip underflow check: denominator >= orderStatus.numerator
                unchecked {
                    // Reduce current numerator so it + supplied = denominator.
                    numerator = denominator - filledNumerator;
                }
            }

            // Increment the filled numerator by the new numerator.
            filledNumerator += numerator; // 将本次交易的交易数量累加到orderStatus中

            // Use assembly to ensure fractional amounts are below max uint120.
            // struct OrderStatus 中，分子、分母都是uint120，因此需要将uint256再转为uint120
            assembly {
                // Check filledNumerator and denominator for uint120 overflow.
                if or(
                    gt(filledNumerator, MaxUint120),
                    gt(denominator, MaxUint120)
                ) {
                    //如果分母大于uint120，则找出分子分母的最大公约数、同时除一下
                    // Derive greatest common divisor using euclidean algorithm.
                    function gcd(_a, _b) -> out {
                        // 计算最大公约数的方法
                        for {

                        } _b {

                        } {
                            let _c := _b
                            _b := mod(_a, _c)
                            _a := _c
                        }
                        out := _a
                    }
                    let scaleDown := gcd(
                        numerator,
                        gcd(filledNumerator, denominator)
                    )

                    // Ensure that the divisor is at least one.
                    let safeScaleDown := add(scaleDown, iszero(scaleDown))

                    // Scale all fractional values down by gcd.
                    numerator := div(numerator, safeScaleDown)
                    filledNumerator := div(filledNumerator, safeScaleDown)
                    denominator := div(denominator, safeScaleDown)

                    // Perform the overflow check a second time.
                    if or(
                        gt(filledNumerator, MaxUint120),
                        gt(denominator, MaxUint120)
                    ) {
                        // Store the Panic error signature.
                        mstore(0, Panic_error_signature)

                        // Set arithmetic (0x11) panic code as initial argument.
                        mstore(Panic_error_offset, Panic_arithmetic)

                        // Return, supplying Panic signature & arithmetic code.
                        revert(0, Panic_error_length)
                    }
                }
            }
            // Skip overflow check: checked above unless numerator is reduced.
            unchecked {
                // Update order status and fill amount, packing struct values.
                orderStatus.isValidated = true;
                orderStatus.isCancelled = false;
                orderStatus.numerator = uint120(filledNumerator); // orderStatus更新
                orderStatus.denominator = uint120(denominator);
            }
        } else {
            // Update order status and fill amount, packing struct values.
            orderStatus.isValidated = true;
            orderStatus.isCancelled = false;
            orderStatus.numerator = uint120(numerator);
            orderStatus.denominator = uint120(denominator); // 首次赋值的话，直接使用advancedOrder参数中的分子、分母
        }

        // Return order hash, a modified numerator, and a modified denominator.
        return (orderHash, numerator, denominator);
    }

    /**
     * @dev Internal function to cancel an arbitrary number of orders. Note that
     *      only the offerer or the zone of a given order may cancel it. Callers
     *      should ensure that the intended order was cancelled by calling
     *      `getOrderStatus` and confirming that `isCancelled` returns `true`.
     *
     * @param orders The orders to cancel.
     *
     * @return cancelled A boolean indicating whether the supplied orders were
     *                   successfully cancelled.
     * 批量取消订单：msg.sender必须是订单的offerer或zone才有权利取消。取消的方式，计算出挂单信息对应的orderHash，然后修改对应的orderStatus
     */
    function _cancel(OrderComponents[] calldata orders)
        internal
        returns (bool cancelled)
    {
        // Ensure that the reentrancy guard is not currently set.
        _assertNonReentrant();

        // Declare variables outside of the loop.
        OrderStatus storage orderStatus;
        address offerer;
        address zone;

        // Skip overflow check as for loop is indexed starting at zero.
        unchecked {
            // Read length of the orders array from memory and place on stack.
            uint256 totalOrders = orders.length;

            // Iterate over each order.
            for (uint256 i = 0; i < totalOrders; ) {
                // Retrieve the order.
                OrderComponents calldata order = orders[i];

                offerer = order.offerer;
                zone = order.zone;

                // Ensure caller is either offerer or zone of the order.
                if (msg.sender != offerer && msg.sender != zone) {
                    revert InvalidCanceller();
                }

                // Derive order hash using the order parameters and the counter.
                bytes32 orderHash = _deriveOrderHash(
                    OrderParameters(
                        offerer,
                        zone,
                        order.offer,
                        order.consideration,
                        order.orderType,
                        order.startTime,
                        order.endTime,
                        order.zoneHash,
                        order.salt,
                        order.conduitKey,
                        order.consideration.length
                    ),
                    order.counter
                );

                // Retrieve the order status using the derived order hash.
                orderStatus = _orderStatus[orderHash];

                // Update the order status as not valid and cancelled.
                orderStatus.isValidated = false;
                orderStatus.isCancelled = true;

                // Emit an event signifying that the order has been cancelled.
                emit OrderCancelled(orderHash, offerer, zone);

                // Increment counter inside body of loop for gas efficiency.
                ++i;
            }
        }

        // Return a boolean indicating that orders were successfully cancelled.
        cancelled = true;
    }

    /**
     * @dev Internal function to validate an arbitrary number of orders, thereby
     *      registering their signatures as valid and allowing the fulfiller to
     *      skip signature verification on fulfillment. Note that validated
     *      orders may still be unfulfillable due to invalid item amounts or
     *      other factors; callers should determine whether validated orders are
     *      fulfillable by simulating the fulfillment call prior to execution.
     *      Also note that anyone can validate a signed order, but only the
     *      offerer can validate an order without supplying a signature.
     *
     * @param orders The orders to validate.
     *
     * @return validated A boolean indicating whether the supplied orders were
     *                   successfully validated.
     * 依次计算出订单对应的orderHash，获取到对应的orderStatus。
     然后验证各个订单：not cancelled、"验证"订单的签名并"修改orderStatus的isValidated=true"(这样后续接单时就不需要再次验证签名了)，
     验证不通过则revert
     */
    function _validate(Order[] calldata orders)
        internal
        returns (bool validated)
    {
        // Ensure that the reentrancy guard is not currently set.
        _assertNonReentrant();

        // Declare variables outside of the loop.
        OrderStatus storage orderStatus;
        bytes32 orderHash;
        address offerer;

        // Skip overflow check as for loop is indexed starting at zero.
        unchecked {
            // Read length of the orders array from memory and place on stack.
            uint256 totalOrders = orders.length;

            // Iterate over each order.
            for (uint256 i = 0; i < totalOrders; ) {
                // Retrieve the order.
                Order calldata order = orders[i];

                // Retrieve the order parameters.
                OrderParameters calldata orderParameters = order.parameters;

                // Move offerer from memory to the stack.
                offerer = orderParameters.offerer;

                // Get current counter & use it w/ params to derive order hash.
                orderHash = _assertConsiderationLengthAndGetOrderHash(
                    orderParameters
                );

                // Retrieve the order status using the derived order hash.
                orderStatus = _orderStatus[orderHash];

                // Ensure order is fillable and retrieve the filled amount.
                _verifyOrderStatus(
                    orderHash,
                    orderStatus,
                    false, // Signifies that partially filled orders are valid.
                    true // Signifies to revert if the order is invalid.
                );

                // If the order has not already been validated...
                if (!orderStatus.isValidated) {
                    // Verify the supplied signature.
                    _verifySignature(offerer, orderHash, order.signature);

                    // Update order status to mark the order as valid.
                    orderStatus.isValidated = true;

                    // Emit an event signifying the order has been validated.
                    emit OrderValidated(
                        orderHash,
                        offerer,
                        orderParameters.zone
                    );
                }

                // Increment counter inside body of the loop for gas efficiency.
                ++i;
            }
        }

        // Return a boolean indicating that orders were successfully validated.
        validated = true;
    }

    /**
     * @dev Internal view function to retrieve the status of a given order by
     *      hash, including whether the order has been cancelled or validated
     *      and the fraction of the order that has been filled.
     *
     * @param orderHash The order hash in question.
     *
     * @return isValidated A boolean indicating whether the order in question
     *                     has been validated (i.e. previously approved or
     *                     partially filled).
     * @return isCancelled A boolean indicating whether the order in question
     *                     has been cancelled.
     * @return totalFilled The total portion of the order that has been filled
     *                     (i.e. the "numerator").
     * @return totalSize   The total size of the order that is either filled or
     *                     unfilled (i.e. the "denominator").
     */
    function _getOrderStatus(bytes32 orderHash)
        internal
        view
        returns (
            bool isValidated,
            bool isCancelled,
            uint256 totalFilled,
            uint256 totalSize
        )
    {
        // Retrieve the order status using the order hash.
        OrderStatus storage orderStatus = _orderStatus[orderHash];

        // Return the fields on the order status.
        return (
            orderStatus.isValidated,
            orderStatus.isCancelled,
            orderStatus.numerator,
            orderStatus.denominator
        );
    }

    /**
     * @dev Internal pure function to check whether a given order type indicates
     *      that partial fills are not supported (e.g. only "full fills" are
     *      allowed for the order in question).
     *
     * @param orderType The order type in question.
     *
     * @return isFullOrder A boolean indicating whether the order type only
     *                     supports full fills.
     根据 orderType验证订单是否支持 部分接单。
     */
    function _doesNotSupportPartialFills(OrderType orderType)
        internal
        pure
        returns (bool isFullOrder)
    {
        // The "full" order types are even, while "partial" order types are odd.
        // Bitwise and by 1 is equivalent to modulo by 2, but 2 gas cheaper.
        assembly {
            // Equivalent to `uint256(orderType) & 1 == 0`.
            isFullOrder := iszero(and(orderType, 1)) // orderType=0、2（对应二进制01）时、不支持partialFill，此时&1=0
        }
    }
}
