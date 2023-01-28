// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { Side, ItemType } from "./ConsiderationEnums.sol";

import {
    OfferItem,
    ConsiderationItem,
    ReceivedItem,
    OrderParameters,
    Fulfillment,
    FulfillmentComponent,
    Execution,
    Order,
    AdvancedOrder,
    CriteriaResolver
} from "./ConsiderationStructs.sol";

import { OrderFulfiller } from "./OrderFulfiller.sol";

import { FulfillmentApplier } from "./FulfillmentApplier.sol";

import "./ConsiderationConstants.sol";

/**
 * @title OrderCombiner
 * @author 0age
 * @notice OrderCombiner contains logic for fulfilling combinations of orders,
 *         either by matching offer items to consideration items or by
 *         fulfilling orders where available.
 */
contract OrderCombiner is OrderFulfiller, FulfillmentApplier {
    /**
     * @dev Derive and set hashes, reference chainId, and associated domain
     *      separator during deployment.
     *
     * @param conduitController A contract that deploys conduits, or proxies
     *                          that may optionally be used to transfer approved
     *                          ERC20/721/1155 tokens.
     */
    constructor(address conduitController) OrderFulfiller(conduitController) {}

    /**
     * @notice Internal function to attempt to fill a group of orders, fully or
     *         partially, with an arbitrary number of items for offer and
     *         consideration per order alongside criteria resolvers containing
     *         specific token identifiers and associated proofs. Any order that
     *         is not currently active, has already been fully filled, or has
     *         been cancelled will be omitted. Remaining offer and consideration
     *         items will then be aggregated where possible as indicated by the
     *         supplied offer and consideration component arrays and aggregated
     *         items will be transferred to the fulfiller or to each intended
     *         recipient, respectively. Note that a failing item transfer or an
     *         issue with order formatting will cause the entire batch to fail.
     *
     * @param advancedOrders            The orders to fulfill along with the
     *                                  fraction of those orders to attempt to
     *                                  fill. Note that both the offerer and the
     *                                  fulfiller must first approve this
     *                                  contract (or a conduit if indicated by
     *                                  the order) to transfer any relevant
     *                                  tokens on their behalf and that
     *                                  contracts must implement
     *                                  `onERC1155Received` in order to receive
     *                                  ERC1155 tokens as consideration. Also
     *                                  note that all offer and consideration
     *                                  components must have no remainder after
     *                                  multiplication of the respective amount
     *                                  with the supplied fraction for an
     *                                  order's partial fill amount to be
     *                                  considered valid.
     * @param criteriaResolvers         An array where each element contains a
     *                                  reference to a specific offer or
     *                                  consideration, a token identifier, and a
     *                                  proof that the supplied token identifier
     *                                  is contained in the merkle root held by
     *                                  the item in question's criteria element.
     *                                  Note that an empty criteria indicates
     *                                  that any (transferable) token
     *                                  identifier on the token in question is
     *                                  valid and that no associated proof needs
     *                                  to be supplied.
     * @param offerFulfillments         An array of FulfillmentComponent arrays
     *                                  indicating which offer items to attempt
     *                                  to aggregate when preparing executions.
     * @param considerationFulfillments An array of FulfillmentComponent arrays
     *                                  indicating which consideration items to
     *                                  attempt to aggregate when preparing
     *                                  executions.
     * @param fulfillerConduitKey       A bytes32 value indicating what conduit,
     *                                  if any, to source the fulfiller's token
     *                                  approvals from. The zero hash signifies
     *                                  that no conduit should be used (and
     *                                  direct approvals set on Consideration).
     * @param recipient                 The intended recipient for all received
     *                                  items.
     * @param maximumFulfilled          The maximum number of orders to fulfill.
     *
     * @return availableOrders An array of booleans indicating if each order
     *                         with an index corresponding to the index of the
     *                         returned boolean was fulfillable or not.
     * @return executions      An array of elements indicating the sequence of
     *                         transfers performed as part of matching the given
     *                         orders.
     */
    function _fulfillAvailableAdvancedOrders(
        AdvancedOrder[] memory advancedOrders,
        CriteriaResolver[] memory criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient,
        uint256 maximumFulfilled
    )
        internal
        returns (bool[] memory availableOrders, Execution[] memory executions)
    {
        // Validate orders, apply amounts, & determine if they utilize conduits.
        _validateOrdersAndPrepareToFulfill( // 计算出本次可接单的各个item的数量，记录在advancedOrders
            advancedOrders,
            criteriaResolvers,
            false, // Signifies that invalid orders should NOT revert. 遇到校验失效的订单，直接跳过该订单、而不是revert整笔交易
            maximumFulfilled,
            recipient
        );

        // Aggregate used offer and consideration items and execute transfers.
        (availableOrders, executions) = _executeAvailableFulfillments(
            advancedOrders,
            offerFulfillments,
            considerationFulfillments,
            fulfillerConduitKey,
            recipient
        );

        // Return order fulfillment details and executions.
        return (availableOrders, executions);
    }

    /**
     * @dev Internal function to validate a group of orders, update their
     *      statuses, reduce amounts by their previously filled fractions, apply
     *      criteria resolvers, and emit OrderFulfilled events.
     *
     * @param advancedOrders    The advanced orders to validate and reduce by
     *                          their previously filled amounts.
     * @param criteriaResolvers An array where each element contains a reference
     *                          to a specific order as well as that order's
     *                          offer or consideration, a token identifier, and
     *                          a proof that the supplied token identifier is
     *                          contained in the order's merkle root. Note that
     *                          a root of zero indicates that any transferable
     *                          token identifier is valid and that no proof
     *                          needs to be supplied.
     * @param revertOnInvalid   A boolean indicating whether to revert on any
     *                          order being invalid; setting this to false will
     *                          instead cause the invalid order to be skipped.
     * @param maximumFulfilled  The maximum number of orders to fulfill.
     * @param recipient         The intended recipient for all received items.
      依次校验各个订单、更新各订单的orderStatus；计算本次可fulfill的各xxxItem的数量（记录在原advancedOrders中），更新累加对应的orderStatus状态变量；
      应用条件解析器；触发OrderFulfilled事件
     */
    function _validateOrdersAndPrepareToFulfill(
        AdvancedOrder[] memory advancedOrders,
        CriteriaResolver[] memory criteriaResolvers,
        bool revertOnInvalid, // 校验订单时 如果无效、是否直接revert整个交易；还是跳过继续处理剩余订单
        uint256 maximumFulfilled, // 本次交易，最多要完成的订单数（实际进行fulfill）
        address recipient // 此处 仅用作OrderFulfilled事件的参数
    ) internal {
        // 该方法会被fulfillAvailableAdvancedOrders 和 matchAdvancedOrders两种external方法所调用
        // Ensure this function cannot be triggered during a reentrant call.
        _setReentrancyGuard();

        // Read length of orders array and place on the stack.
        uint256 totalOrders = advancedOrders.length;

        // Track the order hash for each order being fulfilled.
        // orderHashes中保存的是本次交易中、实际会fulfill的那些order的hash。其他被跳过的订单对应的orderHash设为0
        bytes32[] memory orderHashes = new bytes32[](totalOrders);
        // Override orderHashes length to zero after memory has been allocated.
        assembly {
            mstore(orderHashes, 0)
        }

        // Declare an error buffer indicating status of any native offer items.
        // {00} == 0 => In a match function, no native offer items: allow.
        // {01} == 1 => In a match function, some native offer items: allow.
        // {10} == 2 => Not in a match function, no native offer items: allow.
        // {11} == 3 => Not in a match function, some native offer items: THROW.
        uint256 invalidNativeOfferItemErrorBuffer; //2个bit位的作用：高位用于区分是被fulfillAvailableAdvancedOrders 还是matchAdvancedOrders调用中；低位判断是否包含 native offer items

        // Use assembly to set the value for the second bit of the error buffer.
        assembly {
            // Use the second bit of the error buffer to indicate whether the
            // current function is not matchAdvancedOrders or matchOrders.
            invalidNativeOfferItemErrorBuffer := shl(
                //此处会影响的是倒数第2个bit位
                1,
                gt(
                    // Take the remainder of the selector modulo a magic value.
                    mod(
                        shr(NumBitsAfterSelector, calldataload(0)), //shr(a, b) ：shifts b right by a bits NumBitsAfterSelector=0xe0
                        NonMatchSelector_MagicModulus //69
                    ),
                    // Check if remainder is higher than the greatest remainder
                    // of the two match selectors modulo the magic value.
                    NonMatchSelector_MagicRemainder //0x1d
                )
            )
        }

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Iterate over each order.
            for (uint256 i = 0; i < totalOrders; ++i) {
                // Retrieve the current order.
                // memory 引用类型 赋值给另一个memory的引用时，是不会创建拷贝的。即memory之间通过引用传递完成。
                //advancedOrder是advancedOrders[i]的引用，对advancedOrder的修改会应用到advancedOrders[i]上的！！
                AdvancedOrder memory advancedOrder = advancedOrders[i];
                // Determine if max number orders have already been fulfilled.
                if (maximumFulfilled == 0) {
                    // 标识: 本次交易 如果已达到最大完成数量，则该order要fulfill的数量为0，continue继续遍历下一个order
                    // Mark fill fraction as zero as the order will not be used.
                    advancedOrder.numerator = 0;

                    // Update the length of the orderHashes array.
                    assembly {
                        mstore(orderHashes, add(i, 1))
                    }

                    // Continue iterating through the remaining orders.
                    continue;
                }

                // Validate it, update status, and determine fraction to fill.
                (bytes32 orderHash, uint256 numerator, uint256 denominator) = _validateOrderAndUpdateStatus( // 计算本次实际能够接单的份额并累加到状态变量orderStatus中已完成份额中
                    advancedOrder,
                    criteriaResolvers,
                    revertOnInvalid,
                    orderHashes
                );

                // Update the length of the orderHashes array.
                assembly {
                    mstore(orderHashes, add(i, 1))
                }

                // Do not track hash or adjust prices if order is not fulfilled.
                if (numerator == 0) {
                    // Mark fill fraction as zero if the order is not fulfilled.
                    advancedOrder.numerator = 0;

                    // Continue iterating through the remaining orders.
                    continue;
                }

                //// 如果本次循环的advancedOrder 可以进行fulfill：则根据上方计算出的实际可接单的份额 “计算”每个offer item和consideration item的数量--保存在advancedOrder.parameters.offer或consideration.startAmount字段中（此处还不进行真正的transfer）

                // Otherwise, track the order hash in question.
                orderHashes[i] = orderHash; // 只会保存 实际会进行fulfill的orderHash

                // Decrement the number of fulfilled orders.
                // Skip underflow check as the condition before
                // implies that maximumFulfilled > 0.
                maximumFulfilled--;

                // Place the start time for the order on the stack.
                uint256 startTime = advancedOrder.parameters.startTime;

                // Place the end time for the order on the stack.
                uint256 endTime = advancedOrder.parameters.endTime;

                // Retrieve array of offer items for the order in question.
                OfferItem[] memory offer = advancedOrder.parameters.offer; // offer是一个memory引用类型，对offer的修改也会应用到advancedOrder上

                // Read length of offer array and place on the stack.
                uint256 totalOfferItems = offer.length;

                // Iterate over each offer item on the order.
                for (uint256 j = 0; j < totalOfferItems; ++j) {
                    // 插值方法计算出每个offerItem的实际transfer数量
                    // Retrieve the offer item.
                    OfferItem memory offerItem = offer[j];

                    assembly {
                        // If the offer item is for the native token, set the
                        // first bit of the error buffer to true.
                        invalidNativeOfferItemErrorBuffer := or(
                            invalidNativeOfferItemErrorBuffer,
                            iszero(mload(offerItem)) //offerItem结构体的第一个32字节中保存的是ItemType--0表示NATIVE，此处会影响的是invalidNativeOfferItemErrorBuffer变量最后1个bit位
                        )
                    }

                    // Apply order fill fraction to offer item end amount.
                    uint256 endAmount = _getFraction(
                        numerator,
                        denominator,
                        offerItem.endAmount
                    );

                    // Reuse same fraction if start and end amounts are equal.
                    if (offerItem.startAmount == offerItem.endAmount) {
                        // Apply derived amount to both start and end amount.
                        offerItem.startAmount = endAmount; // 效果和下方else是相同的。
                    } else {
                        // Apply order fill fraction to offer item start amount.
                        offerItem.startAmount = _getFraction(
                            numerator,
                            denominator,
                            offerItem.startAmount
                        );
                    }

                    // Update end amount in memory to match the derived amount.
                    offerItem.endAmount = endAmount;

                    // Adjust offer amount using current time; round down.  插值法计算当前时刻 能够接单的数量
                    offerItem.startAmount = _locateCurrentAmount(
                        offerItem.startAmount,
                        offerItem.endAmount,
                        startTime,
                        endTime,
                        false // round down
                    ); // startAmount字段中保存的就是本次交易中实际能够fulfill的offerItem的数量！！！！！
                }

                // Retrieve array of consideration items for order in question.
                ConsiderationItem[] memory consideration = (
                    advancedOrder.parameters.consideration
                );

                // Read length of consideration array and place on the stack.
                uint256 totalConsiderationItems = consideration.length;

                // Iterate over each consideration item on the order.
                for (uint256 j = 0; j < totalConsiderationItems; ++j) {
                    // 计算方式和上方的offer相同，插值方法计算出每个considerationItem的实际transfer数量
                    // Retrieve the consideration item.
                    ConsiderationItem memory considerationItem = (
                        consideration[j]
                    );

                    // Apply fraction to consideration item end amount.
                    uint256 endAmount = _getFraction(
                        numerator,
                        denominator,
                        considerationItem.endAmount
                    );

                    // Reuse same fraction if start and end amounts are equal.
                    if (
                        considerationItem.startAmount ==
                        considerationItem.endAmount
                    ) {
                        // Apply derived amount to both start and end amount.
                        considerationItem.startAmount = endAmount;
                    } else {
                        // Apply fraction to consideration item start amount.
                        considerationItem.startAmount = _getFraction(
                            numerator,
                            denominator,
                            considerationItem.startAmount
                        );
                    }

                    // Update end amount in memory to match the derived amount.
                    considerationItem.endAmount = endAmount;

                    // Adjust consideration amount using current time; round up.
                    considerationItem.startAmount = (
                        _locateCurrentAmount(
                            considerationItem.startAmount,
                            considerationItem.endAmount,
                            startTime,
                            endTime,
                            true // round up
                        )
                    ); // startAmount字段中保存的就是实际交易的数量，endAmount无用，接下来会内容被覆盖掉

                    // Utilize assembly to manually "shift" the recipient value.
                    // 将considerationItem结构体中的“endAmount”字段 覆盖为 “recipient”，这样下方的_emitOrderFulfilledEvent中就可以直接将considerationItem强制转为ReceivedItem类型
                    assembly {
                        // Write recipient to endAmount, as endAmount is not
                        // used from this point on and can be repurposed to fit
                        // the layout of a ReceivedItem.
                        mstore(
                            add(
                                considerationItem,
                                ReceivedItem_recipient_offset //0x80 old endAmount的位置
                            ),
                            mload(
                                add(
                                    considerationItem,
                                    ConsiderationItem_recipient_offset //0xa0   recipient的位置
                                )
                            )
                        )
                    }
                }
            }
        } // for循环计算各个order中的offerItem、considerationItem结束

        // If the first bit is set, a native offer item was encountered. If the
        // second bit is set in the error buffer, the current function is not
        // matchOrders or matchAdvancedOrders. If the value is three, both the
        // first and second bits were set; in that case, revert with an error.
        if (invalidNativeOfferItemErrorBuffer == 3) {
            //matchOrders or matchAdvancedOrders不支持主网币？？
            revert InvalidNativeOfferItem();
        }

        // Apply criteria resolvers to each order as applicable.
        _applyCriteriaResolvers(advancedOrders, criteriaResolvers); //应用条件解析器，替换advancedOrders中各个xxxItem中的itemType和identifierOrCriteria

        // Emit an event for each order signifying that it has been fulfilled.
        // Skip overflow checks as all for loops are indexed starting at zero.
        // for循环每个order，分别触发一个OrderFulfilled Event
        unchecked {
            // Iterate over each order.
            for (uint256 i = 0; i < totalOrders; ++i) {
                // Do not emit an event if no order hash is present.
                if (orderHashes[i] == bytes32(0)) {
                    continue;
                }

                // Retrieve parameters for the order in question.
                OrderParameters memory orderParameters = (
                    advancedOrders[i].parameters
                );

                // Emit an OrderFulfilled event.
                _emitOrderFulfilledEvent(
                    orderHashes[i],
                    orderParameters.offerer,
                    orderParameters.zone,
                    recipient,
                    orderParameters.offer, // startAmount字段中保存的就是实际交易的数量
                    orderParameters.consideration //上方已经将consideration的“endAmount”修改为recipient
                );
            }
        }
    }

    /**
     * @dev Internal function to fulfill a group of validated orders, fully or
     *      partially, with an arbitrary number of items for offer and
     *      consideration per order and to execute transfers. Any order that is
     *      not currently active, has already been fully filled, or has been
     *      cancelled will be omitted. Remaining offer and consideration items
     *      will then be aggregated where possible as indicated by the supplied
     *      offer and consideration component arrays and aggregated items will
     *      be transferred to the fulfiller or to each intended recipient,
     *      respectively. Note that a failing item transfer or an issue with
     *      order formatting will cause the entire batch to fail.
     *
     * @param advancedOrders            The orders to fulfill along with the
     *                                  fraction of those orders to attempt to
     *                                  fill. Note that both the offerer and the
     *                                  fulfiller must first approve this
     *                                  contract (or the conduit if indicated by
     *                                  the order) to transfer any relevant
     *                                  tokens on their behalf and that
     *                                  contracts must implement
     *                                  `onERC1155Received` in order to receive
     *                                  ERC1155 tokens as consideration. Also
     *                                  note that all offer and consideration
     *                                  components must have no remainder after
     *                                  multiplication of the respective amount
     *                                  with the supplied fraction for an
     *                                  order's partial fill amount to be
     *                                  considered valid.
     * @param offerFulfillments         An array of FulfillmentComponent arrays
     *                                  indicating which offer items to attempt
     *                                  to aggregate when preparing executions.
     * @param considerationFulfillments An array of FulfillmentComponent arrays
     *                                  indicating which consideration items to
     *                                  attempt to aggregate when preparing
     *                                  executions.
     * @param fulfillerConduitKey       A bytes32 value indicating what conduit,
     *                                  if any, to source the fulfiller's token
     *                                  approvals from. The zero hash signifies
     *                                  that no conduit should be used, with
     *                                  direct approvals set on Consideration.
     * @param recipient                 The intended recipient for all received
     *                                  items.
     *
     * @return availableOrders An array of booleans indicating if each order
     *                         with an index corresponding to the index of the
     *                         returned boolean was fulfillable or not.
     * @return executions      An array of elements indicating the sequence of
     *                         transfers performed as part of matching the given
     *                         orders.
     */
    function _executeAvailableFulfillments(
        AdvancedOrder[] memory advancedOrders,
        FulfillmentComponent[][] memory offerFulfillments,
        FulfillmentComponent[][] memory considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient
    )
        internal
        returns (bool[] memory availableOrders, Execution[] memory executions)
    {
        // Retrieve length of offer fulfillments array and place on the stack.
        uint256 totalOfferFulfillments = offerFulfillments.length;

        // Retrieve length of consideration fulfillments array & place on stack.
        uint256 totalConsiderationFulfillments = (
            considerationFulfillments.length
        );

        // Allocate an execution for each offer and consideration fulfillment.
        executions = new Execution[](
            totalOfferFulfillments + totalConsiderationFulfillments
        );

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Track number of filtered executions.
            uint256 totalFilteredExecutions = 0;

            /// 接下来通过两个for循环，分别聚合多个订单的offerItem、considerationItem，使得所有token transfer任务都放到executions数组中
            // Iterate over each offer fulfillment.
            for (uint256 i = 0; i < totalOfferFulfillments; ++i) {
                /// Retrieve the offer fulfillment components in question.
                FulfillmentComponent[] memory components = (
                    offerFulfillments[i]
                );

                // Derive aggregated execution corresponding with fulfillment.
                Execution memory execution = _aggregateAvailable( // 函数内，execution.offer被设置为order.offerer
                    advancedOrders, // 所有订单的offerer相同，不然不能聚合的
                    Side.OFFER,
                    components,
                    fulfillerConduitKey,
                    recipient
                );

                // If offerer and recipient on the execution are the same...
                if (execution.item.recipient == execution.offerer) {
                    // Increment total filtered executions.
                    ++totalFilteredExecutions;
                } else {
                    // Otherwise, assign the execution to the executions array.
                    executions[i - totalFilteredExecutions] = execution;
                }
            }

            // Iterate over each consideration fulfillment.
            for (uint256 i = 0; i < totalConsiderationFulfillments; ++i) {
                /// Retrieve consideration fulfillment components in question.
                FulfillmentComponent[] memory components = (
                    considerationFulfillments[i]
                );

                // Derive aggregated execution corresponding with fulfillment.
                Execution memory execution = _aggregateAvailable(
                    advancedOrders,
                    Side.CONSIDERATION,
                    components,
                    fulfillerConduitKey,
                    address(0) // unused
                );

                // If offerer and recipient on the execution are the same...
                if (execution.item.recipient == execution.offerer) {
                    // Increment total filtered executions.
                    ++totalFilteredExecutions;
                } else {
                    // Otherwise, assign the execution to the executions array.
                    executions[
                        i + totalOfferFulfillments - totalFilteredExecutions
                    ] = execution;
                }
            }

            // If some number of executions have been filtered...
            if (totalFilteredExecutions != 0) {
                // reduce the total length of the executions array.
                assembly {
                    mstore(
                        executions,
                        sub(mload(executions), totalFilteredExecutions)
                    )
                }
            }
        }

        // Revert if no orders are available.
        if (executions.length == 0) {
            revert NoSpecifiedOrdersAvailable();
        }

        // Perform final checks and return. 首先校验一下 订单中规定的所有token transfer（入/出）任务都已放到executions数组中，然后执行各个Execution完成token transfer即可
        availableOrders = _performFinalChecksAndExecuteOrders(
            advancedOrders,
            executions
        );

        return (availableOrders, executions);
    }

    /**
     * @dev Internal function to perform a final check that each consideration
     *      item for an arbitrary number of fulfilled orders has been met and to
     *      trigger associated executions, transferring the respective items.
     *
     * @param advancedOrders     The orders to check and perform executions for.
     * @param executions         An array of elements indicating the sequence of
     *                           transfers to perform when fulfilling the given
     *                           orders.
     *
     * @return availableOrders An array of booleans indicating if each order
     *                         with an index corresponding to the index of the
     *                         returned boolean was fulfillable or not.
     作用：校验advancedOrders各个订单的considerationItem是否为空（），不为空则revert；
     如果为空，说明所有的token transfer任务都已聚合到参数executions，然后执行即可
     */
    function _performFinalChecksAndExecuteOrders(
        AdvancedOrder[] memory advancedOrders,
        Execution[] memory executions
    ) internal returns (bool[] memory availableOrders) {
        // Retrieve the length of the advanced orders array and place on stack.
        uint256 totalOrders = advancedOrders.length;

        // Initialize array for tracking available orders.
        availableOrders = new bool[](totalOrders);

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Iterate over orders to ensure all considerations are met.
            for (uint256 i = 0; i < totalOrders; ++i) {
                // Retrieve the order in question.
                AdvancedOrder memory advancedOrder = advancedOrders[i];

                // Skip consideration item checks for order if not fulfilled.
                if (advancedOrder.numerator == 0) {
                    // Note: orders do not need to be marked as unavailable as a
                    // new memory region has been allocated. Review carefully if
                    // altering compiler version or managing memory manually.
                    continue;
                }

                // Mark the order as available.
                availableOrders[i] = true;

                // Retrieve consideration items to ensure they are fulfilled.
                ConsiderationItem[] memory consideration = (
                    advancedOrder.parameters.consideration
                );

                // Read length of consideration array and place on the stack.
                uint256 totalConsiderationItems = consideration.length;

                // Iterate over each consideration item to ensure it is met.
                for (uint256 j = 0; j < totalConsiderationItems; ++j) {
                    // Retrieve remaining amount on the consideration item.
                    uint256 unmetAmount = consideration[j].startAmount;

                    // Revert if the remaining amount is not zero.
                    if (unmetAmount != 0) {
                        revert ConsiderationNotMet(i, j, unmetAmount);
                    }
                }
                // 上方只校验了consideration侧 ，原因如下：
                // 比如用户A卖出一个NFT，标价为5ETH--- offer:NFT,consideration:5ETH ；用户B想要买入该NFT，提供12ETH---offer:12ETH,consideration:NFT。
                // 两个订单汇总后，总的offer：NFT+12ETH >  总的consideration：5ETH+NFT===》可以撮合。
                //因此只需要保证consideration侧能够match即可，offer侧有剩余也ok，相当于帮用户A省了钱。
                //状态变量orderStauts中也会将订单的numerator/denominator设为1
            }
        }

        // Put ether value supplied by the caller on the stack.
        uint256 etherRemaining = msg.value;

        // Initialize an accumulator array. From this point forward, no new
        // memory regions can be safely allocated until the accumulator is no
        // longer being utilized, as the accumulator operates in an open-ended
        // fashion from this memory pointer; existing memory may still be
        // accessed and modified, however.
        bytes memory accumulator = new bytes(AccumulatorDisarmed);

        // Retrieve the length of the executions array and place on stack.
        uint256 totalExecutions = executions.length;

        // Iterate over each execution.
        for (uint256 i = 0; i < totalExecutions; ) {
            // Retrieve the execution and the associated received item.
            Execution memory execution = executions[i];
            ReceivedItem memory item = execution.item;

            // If execution transfers native tokens, reduce value available.
            if (item.itemType == ItemType.NATIVE) {
                // Ensure that sufficient native tokens are still available.
                if (item.amount > etherRemaining) {
                    revert InsufficientEtherSupplied();
                }

                // Skip underflow check as amount is less than ether remaining.
                unchecked {
                    etherRemaining -= item.amount;
                }
            }

            // Transfer the item specified by the execution.
            _transfer(
                item,
                execution.offerer,
                execution.conduitKey,
                accumulator
            );

            // Skip overflow check as for loop is indexed starting at zero.
            unchecked {
                ++i;
            }
        }

        // Trigger any remaining accumulated transfers via call to the conduit.
        _triggerIfArmed(accumulator);

        // If any ether remains after fulfillments, return it to the caller.
        if (etherRemaining != 0) {
            _transferEth(payable(msg.sender), etherRemaining);
        }

        // Clear the reentrancy guard.
        _clearReentrancyGuard();

        // Return the array containing available orders.
        return (availableOrders);
    }

    /**
     * @dev Internal function to match an arbitrary number of full or partial
     *      orders, each with an arbitrary number of items for offer and
     *      consideration, supplying criteria resolvers containing specific
     *      token identifiers and associated proofs as well as fulfillments
     *      allocating offer components to consideration components.
     *
     * @param advancedOrders    The advanced orders to match. Note that both the
     *                          offerer and fulfiller on each order must first
     *                          approve this contract (or their conduit if
     *                          indicated by the order) to transfer any relevant
     *                          tokens on their behalf and each consideration
     *                          recipient must implement `onERC1155Received` in
     *                          order to receive ERC1155 tokens. Also note that
     *                          the offer and consideration components for each
     *                          order must have no remainder after multiplying
     *                          the respective amount with the supplied fraction
     *                          in order for the group of partial fills to be
     *                          considered valid.
     * @param criteriaResolvers An array where each element contains a reference
     *                          to a specific order as well as that order's
     *                          offer or consideration, a token identifier, and
     *                          a proof that the supplied token identifier is
     *                          contained in the order's merkle root. Note that
     *                          an empty root indicates that any (transferable)
     *                          token identifier is valid and that no associated
     *                          proof needs to be supplied.
     * @param fulfillments      An array of elements allocating offer components
     *                          to consideration components. Note that each
     *                          consideration component must be fully met in
     *                          order for the match operation to be valid.
     *
     * @return executions An array of elements indicating the sequence of
     *                    transfers performed as part of matching the given
     *                    orders.
     */
    function _matchAdvancedOrders(
        AdvancedOrder[] memory advancedOrders,
        CriteriaResolver[] memory criteriaResolvers,
        Fulfillment[] calldata fulfillments
    ) internal returns (Execution[] memory executions) {
        // Validate orders, update order status, and determine item amounts.
        _validateOrdersAndPrepareToFulfill(
            advancedOrders,
            criteriaResolvers,
            true, // Signifies that invalid orders should revert.遇到校验失效的订单，直接revert整笔交易
            advancedOrders.length,
            address(0) // OrderFulfilled event has no recipient when matching.
        );

        // Fulfill the orders using the supplied fulfillments.
        return _fulfillAdvancedOrders(advancedOrders, fulfillments);
    }

    /**
     * @dev Internal function to fulfill an arbitrary number of orders, either
     *      full or partial, after validating, adjusting amounts, and applying
     *      criteria resolvers.
     *
     * @param advancedOrders     The orders to match, including a fraction to
     *                           attempt to fill for each order.
     * @param fulfillments       An array of elements allocating offer
     *                           components to consideration components. Note
     *                           that the final amount of each consideration
     *                           component must be zero for a match operation to
     *                           be considered valid.
     *
     * @return executions An array of elements indicating the sequence of
     *                    transfers performed as part of matching the given
     *                    orders.
     */
    function _fulfillAdvancedOrders(
        AdvancedOrder[] memory advancedOrders,
        Fulfillment[] calldata fulfillments
    ) internal returns (Execution[] memory executions) {
        // Retrieve fulfillments array length and place on the stack.
        uint256 totalFulfillments = fulfillments.length;

        // Allocate executions by fulfillment and apply them to each execution.
        executions = new Execution[](totalFulfillments);

        // Skip overflow checks as all for loops are indexed starting at zero.
        unchecked {
            // Track number of filtered executions.
            uint256 totalFilteredExecutions = 0;

            // Iterate over each fulfillment.
            for (uint256 i = 0; i < totalFulfillments; ++i) {
                /// Retrieve the fulfillment in question. 一个Fulfillment对象 最终对应 一个Executor对象。
                Fulfillment calldata fulfillment = fulfillments[i];

                // Derive the execution corresponding with the fulfillment.
                //比如A订单要卖出 10ETH，B订单想要买入8ETH，那么可以撮合两个订单、从中提取出任务： A->B 8ETH 这个任务放到Executor。订单A的offerItem.amount改为2 代下次for循环时和其他订单再撮合
                Execution memory execution = _applyFulfillment(
                    advancedOrders,
                    fulfillment.offerComponents,
                    fulfillment.considerationComponents
                );

                // If offerer and recipient on the execution are the same...
                // 如果token transfer任务的 token转出者、接收者是同一人，则跳过执行该fulfill任务
                if (execution.item.recipient == execution.offerer) {
                    // Increment total filtered executions.
                    ++totalFilteredExecutions;
                } else {
                    // Otherwise, assign the execution to the executions array. 否则， 追加到executions数组中
                    executions[i - totalFilteredExecutions] = execution;
                }
            }

            // If some number of executions have been filtered...
            if (totalFilteredExecutions != 0) {
                // reduce the total length of the executions array.
                assembly {
                    mstore(
                        executions, // 修改executions的数组长度（executions的第一个32字节保存的是数组长度）
                        sub(mload(executions), totalFilteredExecutions)
                    )
                }
            }
        }

        // Perform final checks and execute orders.
        _performFinalChecksAndExecuteOrders(advancedOrders, executions); // 执行executions中的各个transfer任务

        // Return the executions array.
        return (executions);
    }
}
