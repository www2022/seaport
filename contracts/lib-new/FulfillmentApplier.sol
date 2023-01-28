// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { ItemType, Side } from "./ConsiderationEnums.sol";

import {
    OfferItem,
    ConsiderationItem,
    ReceivedItem,
    OrderParameters,
    AdvancedOrder,
    Execution,
    FulfillmentComponent
} from "./ConsiderationStructs.sol";

import "./ConsiderationConstants.sol";

import {
    FulfillmentApplicationErrors
} from "../interfaces/FulfillmentApplicationErrors.sol";

/**
 * @title FulfillmentApplier
 * @author 0age
 * @notice FulfillmentApplier contains logic related to applying fulfillments,
 *         both as part of order matching (where offer items are matched to
 *         consideration items) as well as fulfilling available orders (where
 *         order items and consideration items are independently aggregated).
 */
contract FulfillmentApplier is FulfillmentApplicationErrors {
    /**
     * @dev Internal pure function to match offer items to consideration items
     *      on a group of orders via a supplied fulfillment.
     *
     * @param advancedOrders          The orders to match.
     * @param offerComponents         An array designating offer components to
     *                                match to consideration components.
     * @param considerationComponents An array designating consideration
     *                                components to match to offer components.
     *                                Note that each consideration amount must
     *                                be zero in order for the match operation
     *                                to be valid.
     *作用： 将多个订单中的 offerItem、considerationItem对应的token Transfer任务 重叠部分聚合到一个Executor中，后期一次执行
     * @return execution The transfer performed as a result of the fulfillment. 这是 offerItem对应的执行器（execution.offerer为挂单者）
     */
    function _applyFulfillment(
        AdvancedOrder[] memory advancedOrders,
        FulfillmentComponent[] calldata offerComponents, //offerComponents中指定了可以各个order中聚合在一起执行的offerItem的索引位置。
        FulfillmentComponent[] calldata considerationComponents // 指定了可以各个order中聚合在一起执行的considerationItem的索引位置 。
    )
        internal
        pure
        returns (
            //参数中指定 的 considerationItem和 offerItem具有相同的(token address, type, tokenId）
            Execution memory execution
        )
    {
        // Ensure 1+ of both offer and consideration components are supplied.
        if (
            offerComponents.length == 0 || considerationComponents.length == 0
        ) {
            revert OfferAndConsiderationRequiredOnFulfillment();
        }

        // Declare a new Execution struct.
        Execution memory considerationExecution;

        // Validate & aggregate consideration items to new Execution object.
        // 1. 根据considerationComponents指定的index，将各个advancedOrder中具有相同token基础信息(amount不同)的ConsiderationItem聚合到一起作为一个transfer任务，保存在considerationExecution中
        // 被汇总时对应在advancedOrder中的amount=0，不然会被重复统计到
        _aggregateValidFulfillmentConsiderationItems(
            advancedOrders,
            considerationComponents,
            considerationExecution
        );

        // Retrieve the consideration item from the execution struct.
        ReceivedItem memory considerationItem = considerationExecution.item;

        // Recipient does not need to be specified because it will always be set
        // to that of the consideration.
        // Validate & aggregate offer items to Execution object.
        // 2. 根据offerComponents指定的index，将各个advancedOrder中具有相同token基础信息(amount不同)的OfferItem聚合到一起作为一个transfer任务，保存在execution中
        _aggregateValidFulfillmentOfferItems(
            advancedOrders,
            offerComponents,
            execution //函数内未设置execution.item.recipient，因为它默认就是当前接单者（offerItem是挂单者转给接单者的）
        );

        // Ensure offer and consideration share types, tokens and identifiers.
        if (
            execution.item.itemType != considerationItem.itemType ||
            execution.item.token != considerationItem.token ||
            execution.item.identifier != considerationItem.identifier
        ) {
            revert MismatchedFulfillmentOfferAndConsiderationComponents();
        }

        ////3. 因为参数中指定 的 considerationItem和 offerItem具有相同的(token address, type, tokenId），因此 offer token转出任务 和 consideration token转入任务也可以合并
        //// execution.item.amount标识的是: 挂单者--> 接单者的token数量；
        //// considerationItem.amount标识的是: 接单者--->??? 的token数量，接收者暂不确定
        //// 将以上两个步骤合并： 挂单者--- execution.item.amount--》接单者--considerationItem.amount ->??? ，根据两个amount的大小关系、分为两种情况：
        //// 1). considerationItem.amount > execution.item.amount的话：挂单者不转给接单者，而是直接转给？？？ 然后，接单者就只需要再给？？？转剩余部分---considerationItem.amount - execution.item.amount
        //// 2). execution.item.amount > considerationItem.amount：挂单者转给？？？所需要的considerationItem.amount，然后，将剩余部分execution.item.amount - considerationItem.amount转给接单者
        /////// 总结1: 通过1） 2）可知，挂单者一定会转给？？？，数量=min{execution.item.amount , considerationItem.amount} ====》 函数最终返回的Execution所要执行的内容
        /////// 总结2: abs(execution.item.amount - considerationItem.amount)部分token的流向为：接单者-> ？？？ or 挂单者->接单者 ----》回写到order中
        if (considerationItem.amount > execution.item.amount) {
            // Retrieve the first consideration component from the fulfillment.
            FulfillmentComponent memory targetComponent = (
                considerationComponents[0]
            );

            // Skip underflow check as the conditional being true implies that
            // considerationItem.amount > execution.item.amount.
            unchecked {
                // Add excess consideration item amount to original order array.
                advancedOrders[targetComponent.orderIndex]
                    .parameters
                    .consideration[targetComponent.itemIndex]
                    .startAmount = (considerationItem.amount -
                    execution.item.amount); // 本次赋值之前，该startAmount在_aggregateValidFulfillmentConsiderationItems被赋值为了0
            } //接单者-> ？？？

            // Reduce total consideration amount to equal the offer amount.
            considerationItem.amount = execution.item.amount; // 此处赋值好像没有再用到
        } else {
            // Retrieve the first offer component from the fulfillment.
            FulfillmentComponent memory targetComponent = offerComponents[0];

            // Skip underflow check as the conditional being false implies that
            // execution.item.amount >= considerationItem.amount.
            unchecked {
                // Add excess offer item amount to the original array of orders.
                advancedOrders[targetComponent.orderIndex]
                    .parameters
                    .offer[targetComponent.itemIndex]
                    .startAmount = (execution.item.amount -
                    considerationItem.amount); // 本次赋值之前，该startAmount在_aggregateValidFulfillmentOfferItems被赋值为了0
            } //挂单者->接单者

            // Reduce total offer amount to equal the consideration amount.
            execution.item.amount = considerationItem.amount;
        }

        // Reuse consideration recipient. 通过上方1）2）分析可知，offerItem对应的execution转移token时 接收者是？？？即considerationItem.recipient
        execution.item.recipient = considerationItem.recipient;

        // Return the final execution that will be triggered for relevant items.
        return execution; // Execution(considerationItem, offerer, conduitKey);
    }

    /**
     * @dev Internal view function to aggregate offer or consideration items
     *      from a group of orders into a single execution via a supplied array
     *      of fulfillment components. Items that are not available to aggregate
     *      will not be included in the aggregated execution.
     *
     * @param advancedOrders        The orders to aggregate.
     * @param side                  The side (i.e. offer or consideration).
     * @param fulfillmentComponents An array designating item components to
     *                              aggregate if part of an available order.
     * @param fulfillerConduitKey   A bytes32 value indicating what conduit, if
     *                              any, to source the fulfiller's token
     *                              approvals from. The zero hash signifies that
     *                              no conduit should be used, with approvals
     *                              set directly on this contract.
     * @param recipient             The intended recipient for all received
     *                              items.
     * 根据side 决定调用_aggregateValidFulfillmentOfferItems or _aggregateValidFulfillmentConsiderationItems，将多个order中的指定item聚合到一个execution
     * @return execution The transfer performed as a result of the fulfillment.
     */
    function _aggregateAvailable(
        AdvancedOrder[] memory advancedOrders,
        Side side,
        FulfillmentComponent[] memory fulfillmentComponents, // 一系列 orderIndex+itemIndex
        bytes32 fulfillerConduitKey,
        address recipient
    ) internal view returns (Execution memory execution) {
        // Skip overflow / underflow checks; conditions checked or unreachable.
        unchecked {
            // Retrieve fulfillment components array length and place on stack.
            // Ensure at least one fulfillment component has been supplied.
            if (fulfillmentComponents.length == 0) {
                revert MissingFulfillmentComponentOnAggregation(side);
            }

            // If the fulfillment components are offer components...
            if (side == Side.OFFER) {
                // Set the supplied recipient on the execution item.
                execution.item.recipient = payable(recipient);

                // Return execution for aggregated items provided by offerer.
                _aggregateValidFulfillmentOfferItems( // 函数内会设置execution.offerer= advancedOrder.offerer(所有advancedOrder的offerer肯定相同，不然会revert)
                    advancedOrders,
                    fulfillmentComponents,
                    execution
                );
            } else {
                // Otherwise, fulfillment components are consideration
                // components. Return execution for aggregated items provided by
                // the fulfiller.
                _aggregateValidFulfillmentConsiderationItems(
                    advancedOrders,
                    fulfillmentComponents,
                    execution
                );

                // Set the caller as the offerer on the execution.
                execution.offerer = msg.sender;

                // Set fulfiller conduit key as the conduit key on execution.
                execution.conduitKey = fulfillerConduitKey;
            }

            // Set the offerer and recipient to null address if execution
            // amount is zero. This will cause the execution item to be skipped.
            if (execution.item.amount == 0) {
                execution.offerer = address(0);
                execution.item.recipient = payable(0);
            }
        }
    }

    /**
     * @dev Internal pure function to aggregate a group of offer items using
     *      supplied directives on which component items are candidates for
     *      aggregation, skipping items on orders that are not available.
     *
     * @param advancedOrders  The orders to aggregate offer items from.
     * @param offerComponents An array of FulfillmentComponent structs
     *                        indicating the order index and item index of each
     *                        candidate offer item for aggregation.
     * @param execution       The execution to apply the aggregation to.
     //作用：校验 offerComponents  中指定的各个order的offerItem 的(same offerer, token, type, tokenId, and conduit preference) 属性是否相同，不同则revert；
     // 如果都相同，就合并到参数execution中（后续一起执行transfer，此处不执行）、原order中的对应offerItem.startAmount设为0

     */
    function _aggregateValidFulfillmentOfferItems(
        AdvancedOrder[] memory advancedOrders,
        FulfillmentComponent[] memory offerComponents,
        Execution memory execution // execution.offerer会在下方被设置为advancedOrder.offerer(所有order的offerer肯定是相同的，不然会revert)
    ) internal pure {
        assembly {
            // Declare function for reverts on invalid fulfillment data.
            function throwInvalidFulfillmentComponentData() {
                // Store the InvalidFulfillmentComponentData error signature.
                mstore(0, InvalidFulfillmentComponentData_error_signature)

                // Return, supplying InvalidFulfillmentComponentData signature.
                revert(0, InvalidFulfillmentComponentData_error_len)
            }

            // Declare function for reverts due to arithmetic overflows.
            function throwOverflow() {
                // Store the Panic error signature.
                mstore(0, Panic_error_signature)

                // Store the arithmetic (0x11) panic code as initial argument.
                mstore(Panic_error_offset, Panic_arithmetic)

                // Return, supplying Panic signature and arithmetic code.
                revert(0, Panic_error_length)
            }
            /////////////////////////////////////////   处理 offerComponents 的第1个元素        ////////////////////////////////////

            // Get position in offerComponents head.
            let fulfillmentHeadPtr := add(offerComponents, OneWord)

            // Retrieve the order index using the fulfillment pointer. 等价于： orderIndex=offerComponents[0].orderIndex
            let orderIndex := mload(mload(fulfillmentHeadPtr))

            // Ensure that the order index is not out of range. 校验: offerComponents[0].orderIndex<advancedOrders.length
            if iszero(lt(orderIndex, mload(advancedOrders))) {
                throwInvalidFulfillmentComponentData()
            }

            // Read advancedOrders[orderIndex] pointer from its array head. 等价于： orderPtr=advancedOrders[orderIndex]
            let orderPtr := mload(
                // Calculate head position of advancedOrders[orderIndex].
                add(add(advancedOrders, OneWord), mul(orderIndex, OneWord))
            )

            // Read the pointer to OrderParameters from the AdvancedOrder.
            let paramsPtr := mload(orderPtr) //paramsPtr 指向的是AdvancedOrder的第一个元素，即OrderParameters结构体的第一个元素“address offerer”

            // Load the offer array pointer.   等价于： offerArrPtr指向的是 OrderParameters结构体的第三个元素offer ===>OfferItem[]类型的起始位置，后边追加的是各个offeritem结构体的引用地址
            let offerArrPtr := mload(
                add(paramsPtr, OrderParameters_offer_head_offset)
            )

            // Retrieve item index using an offset of the fulfillment pointer.  等价于 itemIndex=offerComponents[0].itemIndex
            let itemIndex := mload(
                add(mload(fulfillmentHeadPtr), Fulfillment_itemIndex_offset)
            )
            // Only continue if the fulfillment is not invalid. 校验： offerComponents[0].itemIndex < advancedOrders[orderIndex].offer.length
            if iszero(lt(itemIndex, mload(offerArrPtr))) {
                throwInvalidFulfillmentComponentData()
            }

            // Retrieve consideration item pointer using the item index.
            let offerItemPtr := mload(
                add(
                    // Get pointer to beginning of receivedItem.
                    add(offerArrPtr, OneWord),
                    // Calculate offset to pointer for desired order.
                    mul(itemIndex, OneWord)
                )
            ) //等价于： offerItemPtr指向 advancedOrders[ offerComponents[0].orderIndex ].offer[offerComponents[0].itemIndex]结构体

            // Declare a variable for the final aggregated item amount. 累加到executor中进行transfer的同一token的 总数量
            let amount := 0

            // Create variable to track errors encountered with amount.
            let errorBuffer := 0

            // Only add offer amount to execution amount on a nonzero numerator.
            if mload(add(orderPtr, AdvancedOrder_numerator_offset)) {
                // 如果当前的advancedOrder可接单数量为0、则无需累加amount
                // Retrieve amount pointer using consideration item pointer.
                let amountPtr := add(offerItemPtr, Common_amount_offset) // amountPtr指向的是offerItem.startAmount

                // Set the amount.
                amount := mload(amountPtr)

                // Zero out amount on item to indicate it is credited.
                mstore(amountPtr, 0) // order中的对应offerItem.startAmount设为0

                // Buffer indicating whether issues were found.
                errorBuffer := iszero(amount)
            }

            //////将第一个offerItem的 (offerer即item提供者，itemType,token address, token identifier， conduit--item转移时要用到) 信息保存到execution中(作为后续for循环的比较基准)
            // Retrieve the received item pointer.
            let receivedItemPtr := mload(execution)

            // Set the item type on the received item.
            mstore(receivedItemPtr, mload(offerItemPtr)) // 将offerItem第一个元素 itemType保存到execution

            // Set the token on the received item.
            mstore(
                add(receivedItemPtr, Common_token_offset),
                mload(add(offerItemPtr, Common_token_offset))
            )

            // Set the identifier on the received item.
            mstore(
                add(receivedItemPtr, Common_identifier_offset),
                mload(add(offerItemPtr, Common_identifier_offset))
            )

            // Set the offerer on returned execution using order pointer. paramsPtr指向的是offerer
            mstore(add(execution, Execution_offerer_offset), mload(paramsPtr)) // 将order的offerer设置为本executor的offerer

            // Set conduitKey on returned execution via offset of order pointer.
            mstore(
                add(execution, Execution_conduit_offset),
                mload(add(paramsPtr, OrderParameters_conduit_offset))
            )

            // Calculate the hash of (itemType, token, identifier).
            let dataHash := keccak256(
                receivedItemPtr,
                ReceivedItem_CommonParams_size
            )

            // Get position one word past last element in head of array.
            let endPtr := add(
                offerComponents,
                mul(mload(offerComponents), OneWord)
            )

            /////////////////////////////////////////   for循环处理 offerComponents的 第2个及之后的元素        ////////////////////////////////////
            // Iterate over remaining offer components.
            // prettier-ignore
            for {} lt(fulfillmentHeadPtr,  endPtr) {} {//fulfillmentHeadPtr后边是各个结构体的引用--指针、每个元素只需站32字节，根据引用再去找实际的item存储位置
                // Increment the pointer to the fulfillment head by one word.
                fulfillmentHeadPtr := add(fulfillmentHeadPtr, OneWord)

                // Get the order index using the fulfillment pointer.
                orderIndex := mload(mload(fulfillmentHeadPtr))

                // Ensure the order index is in range.
                if iszero(lt(orderIndex, mload(advancedOrders))) {
                  throwInvalidFulfillmentComponentData()
                }

                // Get pointer to AdvancedOrder element.
                orderPtr := mload(
                    add(
                        add(advancedOrders, OneWord),
                        mul(orderIndex, OneWord)
                    )
                )

                // Only continue if numerator is not zero.
                if iszero(mload(
                    add(orderPtr, AdvancedOrder_numerator_offset)
                )) {
                  continue
                }

                // Read the pointer to OrderParameters from the AdvancedOrder.
                paramsPtr := mload(orderPtr)

                // Load offer array pointer.
                offerArrPtr := mload(
                    add(
                        paramsPtr,
                        OrderParameters_offer_head_offset
                    )
                )

                // Get the item index using the fulfillment pointer.
                itemIndex := mload(add(mload(fulfillmentHeadPtr), OneWord))

                // Throw if itemIndex is out of the range of array.
                if iszero(
                    lt(itemIndex, mload(offerArrPtr))
                ) {
                    throwInvalidFulfillmentComponentData()
                }

                // Retrieve offer item pointer using index.
                offerItemPtr := mload(
                    add(
                        // Get pointer to beginning of receivedItem.
                        add(offerArrPtr, OneWord),
                        // Use offset to pointer for desired order.
                        mul(itemIndex, OneWord)
                    )
                )

                // Retrieve amount pointer using offer item pointer.
                let amountPtr := add(
                      offerItemPtr,
                      Common_amount_offset
                )

                // Add offer amount to execution amount.
                let newAmount := add(amount, mload(amountPtr))

                // Update error buffer: 1 = zero amount, 2 = overflow, 3 = both.
                errorBuffer := or(
                  errorBuffer,
                  or(
                    shl(1, lt(newAmount, amount)),
                    iszero(mload(amountPtr))
                  )
                )

                // Update the amount to the new, summed amount.
                amount := newAmount

                // Zero out amount on original item to indicate it is credited.
                mstore(amountPtr, 0)//order中的对应offerItem.startAmount设为0！！！！！！！！！！

/// 验证当前指定的offerItem的 (offerer即item提供者，itemType,token address, token identifier， conduit--item转移时要用到)  和execution中的相同。
/// 不同则revert！！！
                // Ensure the indicated item matches original item.
                if iszero(
                    and(
                        and(
                          // The offerer must match on both items.
                          eq(
                              mload(paramsPtr),
                              mload(
                                  add(execution, Execution_offerer_offset)
                              )
                          ),
                          // The conduit key must match on both items.
                          eq(
                              mload(
                                  add(
                                      paramsPtr,
                                      OrderParameters_conduit_offset
                                  )
                              ),
                              mload(
                                  add(
                                      execution,
                                      Execution_conduit_offset
                                  )
                              )
                          )
                        ),
                        // The itemType, token, and identifier must match.
                        eq(
                            dataHash,
                            keccak256(
                                offerItemPtr,
                                ReceivedItem_CommonParams_size
                            )
                        )
                    )
                ) {
                    // Throw if any of the requirements are not met.
                    throwInvalidFulfillmentComponentData()
                }
            } // for循环结束
            // Write final amount to execution.
            mstore(add(mload(execution), Common_amount_offset), amount)

            // Determine whether the error buffer contains a nonzero error code.
            if errorBuffer {
                // If errorBuffer is 1, an item had an amount of zero.
                if eq(errorBuffer, 1) {
                    // Store the MissingItemAmount error signature.
                    mstore(0, MissingItemAmount_error_signature)

                    // Return, supplying MissingItemAmount signature.
                    revert(0, MissingItemAmount_error_len)
                }

                // If errorBuffer is not 1 or 0, the sum overflowed.
                // Panic!
                throwOverflow()
            }
        }
    }

    /**
     * @dev Internal pure function to aggregate a group of consideration items
     *      using supplied directives on which component items are candidates
     *      for aggregation, skipping items on orders that are not available.
     *
     * @param advancedOrders          The orders to aggregate consideration
     *                                items from.
     * @param considerationComponents An array of FulfillmentComponent structs
     *                                indicating the order index and item index
     *                                of each candidate consideration item for
     *                                aggregation.    considerationComponents指定了advancedOrders中可以聚合在一个Execution中、一次性执行的 considerationItems
     * @param execution       The execution to apply the aggregation to. 类型{ ReceivedItem item; address offerer; bytes32 conduitKey; }
     
     作用：校验considerationComponents中指定的各个order的各个considerationItem的(token, type, tokenId, recipient)属性是否相同，不同则revert；
     如果都相同，就合并到参数execution中（后续一起执行transfer，此处不执行）、原order中的对应considerationItem.startAmount设为0
     */
    function _aggregateValidFulfillmentConsiderationItems(
        AdvancedOrder[] memory advancedOrders, // 每个order中为msg.sender本笔交易中可以fulfill的各种item的信息（包含item数量）
        FulfillmentComponent[] memory considerationComponents, //数组中每一个元素是一个结构体：uint256 orderIndex + uint256 itemIndex
        Execution memory execution
    ) internal pure {
        // Utilize assembly in order to efficiently aggregate the items.
        assembly {
            // Declare function for reverts on invalid fulfillment data.
            function throwInvalidFulfillmentComponentData() {
                // Store the InvalidFulfillmentComponentData error signature.
                mstore(0, InvalidFulfillmentComponentData_error_signature)

                // Return, supplying InvalidFulfillmentComponentData signature.
                revert(0, InvalidFulfillmentComponentData_error_len)
            }

            // Declare function for reverts due to arithmetic overflows.
            function throwOverflow() {
                // Store the Panic error signature.
                mstore(0, Panic_error_signature)

                // Store the arithmetic (0x11) panic code as initial argument.
                mstore(Panic_error_offset, Panic_arithmetic)

                // Return, supplying Panic signature and arithmetic code.
                revert(0, Panic_error_length)
            }
            /////////////////////////////////////////   处理 considerationComponents的第1个元素        ////////////////////////////////////
            // Get position in considerationComponents head.
            let fulfillmentHeadPtr := add(considerationComponents, OneWord)

            // Retrieve the order index using the fulfillment pointer.
            let orderIndex := mload(mload(fulfillmentHeadPtr))

            // Ensure that the order index is not out of range.
            if iszero(lt(orderIndex, mload(advancedOrders))) {
                //如果considerationComponents中指定的orderIndex超过advancedOrders总长度、则revert
                throwInvalidFulfillmentComponentData()
            }

            // Read advancedOrders[orderIndex] pointer from its array head.
            let orderPtr := mload(
                // Calculate head position of advancedOrders[orderIndex].
                add(add(advancedOrders, OneWord), mul(orderIndex, OneWord))
            ) // 定位到：advancedOrders[orderIndex]==》AdvancedOrder类型

            // Load consideration array pointer.
            let considerationArrPtr := mload(
                add(
                    // Read pointer to OrderParameters from the AdvancedOrder.
                    mload(orderPtr),
                    OrderParameters_consideration_head_offset
                )
            ) // 定位到：advancedOrders[orderIndex].consideration ==>ConsiderationItem[] 类型

            // Retrieve item index using an offset of the fulfillment pointer.
            let itemIndex := mload(
                add(mload(fulfillmentHeadPtr), Fulfillment_itemIndex_offset)
            ) // 定位到：参数 considerationComponents 第一个数组元素中的itemIndex

            // Ensure that the order index is not out of range.
            if iszero(lt(itemIndex, mload(considerationArrPtr))) {
                throwInvalidFulfillmentComponentData()
            }

            // Retrieve consideration item pointer using the item index.
            let considerationItemPtr := mload(
                add(
                    // Get pointer to beginning of receivedItem.
                    add(considerationArrPtr, OneWord),
                    // Calculate offset to pointer for desired order.
                    mul(itemIndex, OneWord)
                )
            ) // considerationItemPtr指向：advancedOrders[ considerationComponents[0].orderIndex ].consideration[ considerationComponents[0].itemIndex ]

            // Declare a variable for the final aggregated item amount.
            let amount := 0

            // Create variable to track errors encountered with amount.
            let errorBuffer := 0

            // Only add consideration amount to execution amount if numerator is
            // greater than zero.
            if mload(add(orderPtr, AdvancedOrder_numerator_offset)) {
                // Retrieve amount pointer using consideration item pointer.
                let amountPtr := add(considerationItemPtr, Common_amount_offset) //amountPtr指向的是某一个considerationItem结构体的startAmount字段

                // Set the amount.
                amount := mload(amountPtr)

                // Set error bit if amount is zero.
                errorBuffer := iszero(amount)

                // Zero out amount on item to indicate it is credited.
                mstore(amountPtr, 0) /// 将该considerationItem的startAmount设为0
            }
            //////将第一个considerationItem的 (itemType,token address, token identifier, recipient) 信息保存到execution中(作为后续for循环的比较基准)
            // Retrieve ReceivedItem pointer from Execution.
            let receivedItem := mload(execution)

            // Set the item type on the received item.
            mstore(receivedItem, mload(considerationItemPtr))

            // Set the token on the received item.
            mstore(
                add(receivedItem, Common_token_offset),
                mload(add(considerationItemPtr, Common_token_offset))
            )

            // Set the identifier on the received item.
            mstore(
                add(receivedItem, Common_identifier_offset),
                mload(add(considerationItemPtr, Common_identifier_offset))
            )

            // Set the recipient on the received item.
            mstore(
                add(receivedItem, ReceivedItem_recipient_offset),
                mload(
                    add(
                        considerationItemPtr,
                        ConsiderationItem_recipient_offset
                    )
                )
            )
            //////   execution 中token基本信息保存完毕 ///////////////////

            // Calculate the hash of (itemType, token, identifier).
            let dataHash := keccak256(
                receivedItem,
                ReceivedItem_CommonParams_size
            )

            // Get position one word past last element in head of array. considerationComponents数组的最后一个元素的内存起始位置
            let endPtr := add(
                considerationComponents,
                mul(mload(considerationComponents), OneWord)
            )
            /////////////////////////////////////////   for循环处理 considerationComponents的 第2个及之后的元素        ////////////////////////////////////
            // Iterate over remaining offer components.
            // prettier-ignore
            for {} lt(fulfillmentHeadPtr,  endPtr) {} {
                // Increment position in considerationComponents head.
                fulfillmentHeadPtr := add(fulfillmentHeadPtr, OneWord)

                // Get the order index using the fulfillment pointer.
                orderIndex := mload(mload(fulfillmentHeadPtr))

                // Ensure the order index is in range.
                if iszero(lt(orderIndex, mload(advancedOrders))) {
                  throwInvalidFulfillmentComponentData()
                }

                // Get pointer to AdvancedOrder element.
                orderPtr := mload(
                    add(
                        add(advancedOrders, OneWord),
                        mul(orderIndex, OneWord)
                    )
                )

                // Only continue if numerator is not zero.
                if iszero(
                    mload(add(orderPtr, AdvancedOrder_numerator_offset))
                ) {
                  continue
                }

                // Load consideration array pointer from OrderParameters.
                considerationArrPtr := mload(
                    add(
                        // Get pointer to OrderParameters from AdvancedOrder.
                        mload(orderPtr),
                        OrderParameters_consideration_head_offset
                    )
                )

                // Get the item index using the fulfillment pointer.
                itemIndex := mload(add(mload(fulfillmentHeadPtr), OneWord))

                // Check if itemIndex is within the range of array.
                if iszero(lt(itemIndex, mload(considerationArrPtr))) {
                    throwInvalidFulfillmentComponentData()
                }

                // Retrieve consideration item pointer using index.
                considerationItemPtr := mload(
                    add(
                        // Get pointer to beginning of receivedItem.
                        add(considerationArrPtr, OneWord),
                        // Use offset to pointer for desired order.
                        mul(itemIndex, OneWord)
                    )
                )

                // Retrieve amount pointer using consideration item pointer.
                let amountPtr := add(
                      considerationItemPtr,
                      Common_amount_offset
                )

                // Add offer amount to execution amount.
                let newAmount := add(amount, mload(amountPtr))

                // Update error buffer: 1 = zero amount, 2 = overflow, 3 = both. 记录amount是否等于0  或是newAmount溢出--如果存在，函数最后会revert
                errorBuffer := or(
                  errorBuffer,
                  or(
                    shl(1, lt(newAmount, amount)),
                    iszero(mload(amountPtr))
                  )
                )

                // Update the amount to the new, summed amount.
                amount := newAmount

                // Zero out amount on original item to indicate it is credited.
                mstore(amountPtr, 0)/// 将considerationItem的startAmount设为0 ！！！！！！！！！！！

                // Ensure the indicated item matches original item.
                // 验证当前considerationItem的 (itemType,token address, token identifier, recipient) 和execution中的相同。不同则revert
                if iszero(
                    and(
                        // Item recipients must match.
                        eq(
                            mload(
                                add(
                                    considerationItemPtr,
                                    ConsiderItem_recipient_offset
                                )
                            ),
                            mload(
                                add(
                                    receivedItem,
                                    ReceivedItem_recipient_offset
                                )
                            )
                        ),
                        // The itemType, token, identifier must match.
                        eq(
                          dataHash,
                          keccak256(
                            considerationItemPtr,
                            ReceivedItem_CommonParams_size
                          )
                        )
                    )
                ) {
                    // Throw if any of the requirements are not met.
                    throwInvalidFulfillmentComponentData()
                }
            } // for循环处理 considerationComponents中各个元素结束

            // Write final amount to execution.
            mstore(add(receivedItem, Common_amount_offset), amount)

            // Determine whether the error buffer contains a nonzero error code.
            if errorBuffer {
                // If errorBuffer is 1, an item had an amount of zero.
                if eq(errorBuffer, 1) {
                    // Store the MissingItemAmount error signature.
                    mstore(0, MissingItemAmount_error_signature)

                    // Return, supplying MissingItemAmount signature.
                    revert(0, MissingItemAmount_error_len)
                }

                // If errorBuffer is not 1 or 0, the sum overflowed.
                // Panic!
                throwOverflow()
            }
        }
    }
}
