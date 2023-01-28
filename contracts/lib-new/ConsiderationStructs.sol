// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import {
    OrderType,
    BasicOrderType,
    ItemType,
    Side
} from "./ConsiderationEnums.sol";

/**
 * @dev An order contains eleven components: an offerer, a zone (or account that
 *      can cancel the order or restrict who can fulfill the order depending on
 *      the type), the order type (specifying partial fill support as well as
 *      restricted order status), the start and end time, a hash that will be
 *      provided to the zone when validating restricted orders, a salt, a key
 *      corresponding to a given conduit, a counter, and an arbitrary number of
 *      offer items that can be spent along with consideration items that must
 *      be received by their respective recipient.
 */
struct OrderComponents {
    address offerer;
    address zone;
    OfferItem[] offer; // 此处指定的是 挂单者offerer要付给接单者的token（offerer可能是接单者、也可能是挂单者）
    ConsiderationItem[] consideration; // 此处指定的是 接单者要付出的token（token接收者在参数内指定）
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey; // 挂单者转出token时要使用的conduit对应的key
    uint256 counter; //订单nonce值
}

/**
 * @dev An offer item has five components: an item type (ETH or other native
 *      tokens, ERC20, ERC721, and ERC1155, as well as criteria-based ERC721 and
 *      ERC1155), a token address, a dual-purpose "identifierOrCriteria"
 *      component that will either represent a tokenId or a merkle root
 *      depending on the item type, and a start and end amount that support
 *      increasing or decreasing amounts over the duration of the respective
 *      order.
 */
struct OfferItem {
    // 挂单者要转给接单者的token信息
    ItemType itemType;
    address token;
    //identifierOrCriteria= 0 的话，表示买家可以购买 offerer 拥有该token中的任意 token id（不需要校验Merkle tree！！）
    uint256 identifierOrCriteria; //根据itemType类型，含义不同：对于erc721、1155，identifier为tokenId；如果itemType是 ..._WITH_CRITERIA,identifier为Merkle Root。接单时，入参数中的CriteriaResolver配合使用
    uint256 startAmount;
    uint256 endAmount;
}

/**
 * @dev A consideration item has the same five components as an offer item and
 *      an additional sixth component designating the required recipient of the
 *      item.
 */
struct ConsiderationItem {
    // 接单者要转出的token信息
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria; // tokenId 或是一组tokenId组成的Merkle Root(表示接单者可以选择该组tokenId中的任一个)。
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient; // token接收者。转出者为msg.sender
}

/**
 * @dev A spent item is translated from a utilized offer item and has four
 *      components: an item type (ETH or other native tokens, ERC20, ERC721, and
 *      ERC1155), a token address, a tokenId, and an amount.
 */
struct SpentItem {
    //用在 event OrderFulfilled 中时，表示offer items，即挂单者转给 接单者 的token信息
    ItemType itemType;
    address token;
    uint256 identifier;
    uint256 amount;
}

/**
 * @dev A received item is translated from a utilized consideration item and has
 *      the same four components as a spent item, as well as an additional fifth
 *      component designating the required recipient of the item.
 *
 */
struct ReceivedItem {
    //用在 event OrderFulfilled 中时，由两部分组成：接单者 转给 挂单者的token + additionalRecipients接收到的token信息（发送者可能是挂单者、也可能是接单者）
    ItemType itemType;
    address token;
    uint256 identifier; //对于erc721、1155，表示tokenid
    uint256 amount;
    address payable recipient;
}

/**
 * @dev For basic orders involving ETH / native / ERC20 <=> ERC721 / ERC1155
 *      matching, a group of six functions may be called that only requires a
 *      subset of the usual order arguments. Note the use of a "basicOrderType"
 *      enum; this represents both the usual order type as well as the "route"
 *      of the basic order (a simple derivation function for the basic order
 *      type is `basicOrderType = orderType + (4 * basicOrderRoute)`.)
 */
struct BasicOrderParameters {
    // calldata offset：0x24（0x4字节的函数选择器+0x20字节的指示struct实际存储起始位置的偏移量）
    address considerationToken; // 0x24
    uint256 considerationIdentifier; // 0x44
    uint256 considerationAmount; // 0x64      该笔订单中，接单者要转出的token总数量：如果是ERC20或NATIVE，则先转给additionalRecipients，剩余部分转给挂单者
    address payable offerer; // 0x84
    address zone; // 0xa4
    address offerToken; // 0xc4
    uint256 offerIdentifier; // 0xe4
    uint256 offerAmount; // 0x104   该笔订单中，挂单者要转出的token总数量：接单者(及additionalRecipients) 的token信息
    BasicOrderType basicOrderType; // 0x124
    uint256 startTime; // 0x144
    uint256 endTime; // 0x164
    bytes32 zoneHash; // 0x184
    uint256 salt; // 0x1a4
    bytes32 offererConduitKey; // 0x1c4 挂单者要使用的conduitKey（如果不为空，则挂单者要支付ERC20、721、1155时会使用该key对应的Conduit完成token transfer）
    bytes32 fulfillerConduitKey; // 0x1e4  接单者msg.sender要使用的conduitKey
    uint256 totalOriginalAdditionalRecipients; // 0x204     挂单者挂单时 additionalRecipients数组的长度
    AdditionalRecipient[] additionalRecipients; // 0x224   offerer或fulfiller要转出的其他native或ERC20信息，数量已包含在offerAmount或considerationAmount中 （token 由offerToken或者considerationToken字段指定 ，支付这些token的一方同时是该处的转出者）。 原始挂单时挂单者指定前totalOriginalAdditionalRecipients个元素，接单时可能又添加剩余部分（添加的部分 是从接单者的利润中扣除的、不会减少挂单者的利润，因此只要接单者愿意、可随便增加）
    bytes signature; // 0x244 signature.length=65   挂单签名
    // Total length, excluding dynamic array data: 0x264 (580)
}

/**
 * @dev Basic orders can supply any number of additional recipients, with the
 *      implied assumption that they are supplied from the offered ETH (or other
 *      native token) or ERC20 token for the order.
 */
struct AdditionalRecipient {
    uint256 amount;
    address payable recipient;
}

/**
 * @dev The full set of order components, with the exception of the counter,
 *      must be supplied when fulfilling more sophisticated orders or groups of
 *      orders. The total number of original consideration items must also be
 *      supplied, as the caller may specify additional consideration items.
 */
struct OrderParameters {
    address offerer; // 0x00
    address zone; // 0x20
    OfferItem[] offer; // 0x40
    ConsiderationItem[] consideration; // 0x60 原始挂单ConsiderationItem[]的基础上，再加上当前接单者的
    OrderType orderType; // 0x80
    uint256 startTime; // 0xa0
    uint256 endTime; // 0xc0
    bytes32 zoneHash; // 0xe0
    uint256 salt; // 0x100
    bytes32 conduitKey; // 0x120
    uint256 totalOriginalConsiderationItems; // 0x140  该参数指定的是原始挂单时ConsiderationItem[]的长度，小于等于当前的consideration长度
    // offer.length                          // 0x160
}

/**
 * @dev Orders require a signature in addition to the other order parameters.
 //与AdvancedOrder相比，Order不支持订单部分执行
 */
struct Order {
    OrderParameters parameters;
    bytes signature;
}

/**
 * @dev Advanced orders include a numerator (i.e. a fraction to attempt to fill)
 *      and a denominator (the total size of the order) in addition to the
 *      signature and other order parameters. It also supports an optional field
 *      for supplying extra data; this data will be included in a staticcall to
 *      `isValidOrderIncludingExtraData` on the zone for the order if the order
 *      type is restricted and the offerer or zone are not the caller.
 */
struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator; // 表示本次交易，要完成订单的百分比。以原始订单的offer、consideration 数量为基准
    bytes signature;
    bytes extraData;
}

/**
 * @dev Orders can be validated (either explicitly via `validate`, or as a
 *      consequence of a full or partial fill), specifically cancelled (they can
 *      also be cancelled in bulk via incrementing a per-zone counter), and
 *      partially or fully filled (with the fraction filled represented by a
 *      numerator and denominator).
 */
struct OrderStatus {
    bool isValidated; // orderHash对应的挂单签名是否已验证过
    bool isCancelled;
    uint120 numerator;
    uint120 denominator; // numerator/denominator标识该订单已partially filled的百分比，首次赋值直接使用第一次接单时参数中指定的分子、分母
}

/**
 * @dev A criteria resolver specifies an order, side (offer vs. consideration),
 *      and item index. It then provides a chosen identifier (i.e. tokenId)
 *      alongside a merkle proof demonstrating the identifier meets the required
 *      criteria.
 */
struct CriteriaResolver {
    uint256 orderIndex; // 用于一次成交多个订单的情况，表明需要校验哪个订单
    Side side; // offer 或者 consideration，表明需要校验的是订单中的哪一方
    uint256 index; //offer 或者 consideration 中的元素索引，找出具体要校验哪个元素。 对应的是offer[index]或consideration[index]，由side决定
    uint256 identifier; // 想要成交的具体tokenId（merkle leaf）。merkle root在offerItem或者 considerationItem中的identifierOrCriteria字段指定
    bytes32[] criteriaProof; // merkle proof，与上方的identifier（Leaf）和merkle root一起使用
}

/**
 * @dev A fulfillment is applied to a group of orders. It decrements a series of
 *      offer and consideration items, then generates a single execution
 *      element. A given fulfillment can be applied to as many offer and
 *      consideration items as desired, but must contain at least one offer and
 *      at least one consideration that match. The fulfillment must also remain
 *      consistent on all key parameters across all offer items (same offerer,
 *      token, type, tokenId, and conduit preference) as well as across all
 *      consideration items (token, type, tokenId, and recipient).
 */
struct Fulfillment {
    // 一个Fulfillment对象 最终对应 一个Executor对象。
    //下方的offerComponents和considerationComponents任务重能够将 重叠的部分提取出来合并到Executor中一次执行完成，差额部分更新到order中。
    //（比如A订单要卖出 10ETH，B订单想要买入8ETH，那么可以从中提取出任务： A->B 8ETH 放到Executor ，然后将订单A中的卖出数量更改为 2）
    FulfillmentComponent[] offerComponents; //该数组中各个FulfillmentComponent 指定的所有offerItem 的(same offerer, token, type, tokenId, and conduit preference) 必须相同，不然不能合并到一个Executor中执行transfer
    FulfillmentComponent[] considerationComponents; //该数组中各个FulfillmentComponent 指定的所有 considerationItem 的(token, type, tokenId, recipient)必须相同，不然不能合并到一个Executor中执行transfer
}

/**
 * @dev Each fulfillment component contains one index referencing a specific
 *      order and another referencing a specific offer or consideration item.
 */
struct FulfillmentComponent {
    uint256 orderIndex;
    uint256 itemIndex;
}

/**
 * @dev An execution is triggered once all consideration items have been zeroed
 *      out. It sends the item in question from the offerer to the item's
 *      recipient, optionally sourcing approvals from either this contract
 *      directly or from the offerer's chosen conduit if one is specified. An
 *      execution is not provided as an argument, but rather is derived via
 *      orders, criteria resolvers, and fulfillments (where the total number of
 *      executions will be less than or equal to the total number of indicated
 *      fulfillments) and returned as part of `matchOrders`.
 */
struct Execution {
    ReceivedItem item; // 包含token的基本信息、转出数量、接收者地址
    address offerer; // 执行token transfer时，token的提供者（转出者）
    bytes32 conduitKey; // offerer转出token时要使用的conduit？
}
