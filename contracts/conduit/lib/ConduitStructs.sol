// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import { ConduitItemType } from "./ConduitEnums.sol";

struct ConduitTransfer {
    ConduitItemType itemType;
    address token;
    address from;
    address to;
    uint256 identifier; //根据itemType类型，含义不同：对于erc721、1155，identifier为确定的一个 tokenId；如果itemType是 ..._WITH_CRITERIA,identifier为Merkle Root，具体的tokenId由交易入参中的struct CriteriaResolver指定
    uint256 amount;
}

struct ConduitBatch1155Transfer {
    address token;
    address from;
    address to;
    uint256[] ids;
    uint256[] amounts;
}
