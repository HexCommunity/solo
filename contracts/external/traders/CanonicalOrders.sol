/*

    Copyright 2019 dYdX Trading Inc.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity 0.5.7;
pragma experimental ABIEncoderV2;

import { SafeMath } from "openzeppelin-solidity/contracts/math/SafeMath.sol";
import { Ownable } from "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import { IAutoTrader } from "../../protocol/interfaces/IAutoTrader.sol";
import { ICallee } from "../../protocol/interfaces/ICallee.sol";
import { Account } from "../../protocol/lib/Account.sol";
import { Math } from "../../protocol/lib/Math.sol";
import { Monetary } from "../../protocol/lib/Monetary.sol";
import { Require } from "../../protocol/lib/Require.sol";
import { Types } from "../../protocol/lib/Types.sol";
import { OnlySolo } from "../helpers/OnlySolo.sol";
import { TypedSignature } from "../lib/TypedSignature.sol";


/**
 * @title CanonicalOrders
 * @author dYdX
 *
 * Allows for Canonical Orders to be used with dYdX
 */
contract CanonicalOrders is
    Ownable,
    OnlySolo,
    IAutoTrader,
    ICallee
{
    using Math for uint256;
    using SafeMath for uint256;
    using Types for Types.Par;
    using Types for Types.Wei;

    // ============ Constants ============

    bytes32 constant private FILE = "CanonicalOrders";

    // EIP191 header for EIP712 prefix
    bytes2 constant private EIP191_HEADER = 0x1901;

    // EIP712 Domain Name value
    string constant private EIP712_DOMAIN_NAME = "CanonicalOrders";

    // EIP712 Domain Version value
    string constant private EIP712_DOMAIN_VERSION = "1.0";

    // Hash of the EIP712 Domain Separator Schema
    /* solium-disable-next-line indentation */
    bytes32 constant private EIP712_DOMAIN_SEPARATOR_SCHEMA_HASH = keccak256(abi.encodePacked(
        "EIP712Domain(",
        "string name,",
        "string version,",
        "uint256 chainId,",
        "address verifyingContract",
        ")"
    ));

    // Hash of the EIP712 CanonicalOrder struct
    /* solium-disable-next-line indentation */
    bytes32 constant private EIP712_ORDER_STRUCT_SCHEMA_HASH = keccak256(abi.encodePacked(
        "CanonicalOrder(",
        "bytes32 flags,",
        "uint256 baseMarket,",
        "uint256 quoteMarket,",
        "uint256 amount,",
        "uint256 limitPrice,",
        "uint256 triggerPrice,",
        "uint256 limitFee,",
        "address makerAccountOwner,",
        "uint256 makerAccountNumber,",
        "address taker,",
        "uint256 expiration",
        ")"
    ));

    // Number of bytes in an Order struct (plus orderInfo.price/fee/isNegativeFee)
    uint256 constant private NUM_ORDER_BYTES = 448;

    // Number of bytes in a typed signature
    uint256 constant private NUM_SIGNATURE_BYTES = 66;

    // The number of decimal places of precision in the price ratio of a triggerPrice
    uint256 constant private PRICE_BASE = 10 ** 18;

    // Bitmasks for the order.flag argument
    bytes32 constant private IS_BUY_FLAG = bytes32(uint256(0xf));
    bytes32 constant private IS_DECREASE_ONLY_FLAG = bytes32(uint256(0xf0));
    bytes32 constant private IS_NEGATIVE_FEE_FLAG = bytes32(uint256(0xf00));

    // ============ Enums ============

    enum OrderStatus {
        Null,
        Approved,
        Canceled
    }

    enum CallFunctionType {
        Approve,
        Cancel,
        SetTradeArgs
    }

    // ============ Structs ============

    struct Order {
        bytes32 flags; // salt, negativeFee, decreaseOnly, isBuy
        uint256 baseMarket;
        uint256 quoteMarket;
        uint256 amount;
        uint256 limitPrice;
        uint256 triggerPrice;
        uint256 limitFee;
        address makerAccountOwner;
        uint256 makerAccountNumber;
        address taker;
        uint256 expiration;
    }

    struct TradeArgs {
        uint256 price;
        uint128 fee;
        bool isNegativeFee;
    }

    struct OrderInfo {
        Order order;
        TradeArgs tradeArgs;
        bytes32 orderHash;
    }

    struct OrderQueryOutput {
        OrderStatus orderStatus;
        uint256 filledAmount;
    }

    // ============ Events ============

    event ContractStatusSet(
        bool operational
    );

    event LogCanonicalOrderCanceled(
        bytes32 indexed orderHash,
        address indexed canceler,
        uint256 baseMarket,
        uint256 quoteMarket
    );

    event LogCanonicalOrderApproved(
        bytes32 indexed orderHash,
        address indexed approver,
        uint256 baseMarket,
        uint256 quoteMarket
    );

    event LogCanonicalOrderFilled(
        bytes32 indexed orderHash,
        address indexed orderMaker,
        uint256 fillAmount,
        uint256 totalFilledAmount,
        uint256 price,
        uint256 fee,
        bool isNegativeFee
    );

    // ============ Immutable Storage ============

    // Hash of the EIP712 Domain Separator data
    bytes32 public EIP712_DOMAIN_HASH;

    // ============ Mutable Storage ============

    // true if this contract can process orders
    bool public g_isOperational;

    // order hash => filled amount (in baseAmount)
    mapping (bytes32 => uint256) public g_filledAmount;

    // order hash => status
    mapping (bytes32 => OrderStatus) public g_status;

    // stored tradeArgs
    TradeArgs public g_tradeArgs;

    // ============ Constructor ============

    constructor (
        address soloMargin,
        uint256 chainId
    )
        public
        OnlySolo(soloMargin)
    {
        g_isOperational = true;

        /* solium-disable-next-line indentation */
        EIP712_DOMAIN_HASH = keccak256(abi.encode(
            EIP712_DOMAIN_SEPARATOR_SCHEMA_HASH,
            keccak256(bytes(EIP712_DOMAIN_NAME)),
            keccak256(bytes(EIP712_DOMAIN_VERSION)),
            chainId,
            address(this)
        ));
    }

    // ============ Admin Functions ============

    /**
     * The owner can shut down the exchange.
     */
    function shutDown()
        external
        onlyOwner
    {
        g_isOperational = false;
        emit ContractStatusSet(false);
    }

    /**
     * The owner can start back up the exchange.
     */
    function startUp()
        external
        onlyOwner
    {
        g_isOperational = true;
        emit ContractStatusSet(true);
    }

    // ============ External Functions ============

    /**
     * Cancels an order. Cannot already be canceled.
     *
     * @param  order  The order to cancel
     */
    function cancelOrder(
        Order memory order
    )
        public
    {
        cancelOrderInternal(msg.sender, order);
    }

    /**
     * Approves an order. Cannot already be approved or canceled.
     *
     * @param  order  The order to approve
     */
    function approveOrder(
        Order memory order
    )
        public
    {
        approveOrderInternal(msg.sender, order);
    }

    // ============ Only-Solo Functions ============

    /**
     * Allows traders to make trades approved by this smart contract. The active trader's account is
     * the takerAccount and the passive account (for which this contract approves trades
     * on-behalf-of) is the makerAccount.
     *
     * @param  inputMarketId   The market for which the trader specified the original amount
     * @param  outputMarketId  The market for which the trader wants the resulting amount specified
     * @param  makerAccount    The account for which this contract is making trades
     * @param  takerAccount    The account requesting the trade
     * @param  oldInputPar     The par balance of the makerAccount for inputMarketId pre-trade
     * @param  newInputPar     The par balance of the makerAccount for inputMarketId post-trade
     * @param  inputWei        The change in token amount for the makerAccount for the inputMarketId
     * @param  data            Arbitrary data passed in by the trader
     * @return                 The AssetAmount for the makerAccount for the outputMarketId
     */
    function getTradeCost(
        uint256 inputMarketId,
        uint256 outputMarketId,
        Account.Info memory makerAccount,
        Account.Info memory takerAccount,
        Types.Par memory oldInputPar,
        Types.Par memory newInputPar,
        Types.Wei memory inputWei,
        bytes memory data
    )
        public
        onlySolo(msg.sender)
        returns (Types.AssetAmount memory)
    {
        Require.that(
            g_isOperational,
            FILE,
            "Contract is not operational"
        );

        OrderInfo memory orderInfo = getOrderAndValidateSignature(data);

        verifyOrderAndAccountsAndMarkets(
            orderInfo,
            makerAccount,
            takerAccount,
            inputMarketId,
            outputMarketId,
            inputWei
        );

        Types.AssetAmount memory assetAmount = getOutputAssetAmount(
            inputMarketId,
            outputMarketId,
            inputWei,
            orderInfo
        );

        if (isDecreaseOnly(orderInfo.order)) {
            verifyDecreaseOnly(
                oldInputPar,
                newInputPar,
                assetAmount,
                makerAccount,
                outputMarketId
            );
        }

        return assetAmount;
    }

    /**
     * Allows users to send this contract arbitrary data.
     *
     *  param  sender       (unused)
     * @param  accountInfo  The account from which the data is being sent
     * @param  data         Arbitrary data given by the sender
     */
    function callFunction(
        address /* sender */,
        Account.Info memory accountInfo,
        bytes memory data
    )
        public
        onlySolo(msg.sender)
    {
        CallFunctionType cft = abi.decode(data, (CallFunctionType));

        if (cft == CallFunctionType.SetTradeArgs) {
            TradeArgs memory tradeArgs;
            (cft, tradeArgs) = abi.decode(data, (CallFunctionType, TradeArgs));
            g_tradeArgs = tradeArgs;
        } else {
            Order memory order;
            (cft, order) = abi.decode(data, (CallFunctionType, Order));
            if (cft == CallFunctionType.Approve) {
                approveOrderInternal(accountInfo.owner, order);
            } else {
                assert(cft == CallFunctionType.Cancel);
                cancelOrderInternal(accountInfo.owner, order);
            }
        }
    }

    // ============ Getters ============

    /**
     * Returns the status and the filled amount of several orders.
     */
    function getOrderStates(
        bytes32[] memory orderHashes
    )
        public
        view
        returns(OrderQueryOutput[] memory)
    {
        uint256 numOrders = orderHashes.length;
        OrderQueryOutput[] memory output = new OrderQueryOutput[](numOrders);

        // for each order
        for (uint256 i = 0; i < numOrders; i++) {
            bytes32 orderHash = orderHashes[i];
            output[i] = OrderQueryOutput({
                orderStatus: g_status[orderHash],
                filledAmount: g_filledAmount[orderHash]
            });
        }
        return output;
    }

    // ============ Private Storage Functions ============

    /**
     * Cancels an order as long as it is not already canceled.
     */
    function cancelOrderInternal(
        address canceler,
        Order memory order
    )
        private
    {
        Require.that(
            canceler == order.makerAccountOwner,
            FILE,
            "Canceler must be maker"
        );
        bytes32 orderHash = getOrderHash(order);
        g_status[orderHash] = OrderStatus.Canceled;
        emit LogCanonicalOrderCanceled(
            orderHash,
            canceler,
            order.baseMarket,
            order.quoteMarket
        );
    }

    /**
     * Approves an order as long as it is not already approved or canceled.
     */
    function approveOrderInternal(
        address approver,
        Order memory order
    )
        private
    {
        Require.that(
            approver == order.makerAccountOwner,
            FILE,
            "Approver must be maker"
        );
        bytes32 orderHash = getOrderHash(order);
        Require.that(
            g_status[orderHash] != OrderStatus.Canceled,
            FILE,
            "Cannot approve canceled order",
            orderHash
        );
        g_status[orderHash] = OrderStatus.Approved;
        emit LogCanonicalOrderApproved(
            orderHash,
            approver,
            order.baseMarket,
            order.quoteMarket
        );
    }

    // ============ Private Helper Functions ============

    /**
     * Verifies that the order is still fillable for the particular accounts and markets specified.
     */
    function verifyOrderAndAccountsAndMarkets(
        OrderInfo memory orderInfo,
        Account.Info memory makerAccount,
        Account.Info memory takerAccount,
        uint256 inputMarketId,
        uint256 outputMarketId,
        Types.Wei memory inputWei
    )
        private
        view
    {
        // verify triggerPrice
        if (orderInfo.order.triggerPrice > 0) {
            uint256 currentPrice = getCurrentPrice(
                orderInfo.order.baseMarket,
                orderInfo.order.quoteMarket
            );
            Require.that(
                isBuy(orderInfo.order)
                    ? currentPrice >= orderInfo.order.triggerPrice
                    : currentPrice <= orderInfo.order.triggerPrice,
                FILE,
                "Order triggerPrice not triggered",
                currentPrice
            );
        }

        // verify expriy
        Require.that(
            orderInfo.order.expiration == 0 || orderInfo.order.expiration >= block.timestamp,
            FILE,
            "Order expired",
            orderInfo.orderHash
        );

        // verify maker
        Require.that(
            makerAccount.owner == orderInfo.order.makerAccountOwner &&
            makerAccount.number == orderInfo.order.makerAccountNumber,
            FILE,
            "Order maker account mismatch",
            orderInfo.orderHash
        );

        // verify taker
        Require.that(
            orderInfo.order.taker == address(0) || orderInfo.order.taker == takerAccount.owner,
            FILE,
            "Order taker mismatch",
            orderInfo.orderHash
        );

        // verify markets
        Require.that(
            (
                orderInfo.order.baseMarket == outputMarketId &&
                orderInfo.order.quoteMarket == inputMarketId
            ) || (
                orderInfo.order.quoteMarket == outputMarketId &&
                orderInfo.order.baseMarket == inputMarketId
            ),
            FILE,
            "Market mismatch",
            orderInfo.orderHash
        );

        // verify inputWei
        Require.that(
            !inputWei.isZero(),
            FILE,
            "InputWei is zero",
            orderInfo.orderHash
        );
        Require.that(
            inputWei.sign ==
                ((orderInfo.order.baseMarket == inputMarketId) == isBuy(orderInfo.order)),
            FILE,
            "InputWei sign mismatch",
            orderInfo.orderHash
        );
    }

    /**
     * Verifies that the order is decreasing the size of the maker's position.
     */
    function verifyDecreaseOnly(
        Types.Par memory oldInputPar,
        Types.Par memory newInputPar,
        Types.AssetAmount memory assetAmount,
        Account.Info memory makerAccount,
        uint256 outputMarketId
    )
        private
        view
    {
        // verify that the balance of inputMarketId is not increased
        Require.that(
            newInputPar.isZero()
            || (newInputPar.value <= oldInputPar.value && newInputPar.sign == oldInputPar.sign),
            FILE,
            "inputMarket not decreased"
        );

        // verify that the balance of outputMarketId is not increased
        Types.Wei memory oldOutputWei = SOLO_MARGIN.getAccountWei(makerAccount, outputMarketId);
        Require.that(
            assetAmount.value == 0
            || (assetAmount.value <= oldOutputWei.value && assetAmount.sign != oldOutputWei.sign),
            FILE,
            "outputMarket not decreased"
        );
    }

    /**
     * Returns the AssetAmount for the outputMarketId given the order and the inputs. Updates the
     * filled amount of the order in storage.
     */
    function getOutputAssetAmount(
        uint256 inputMarketId,
        uint256 outputMarketId,
        Types.Wei memory inputWei,
        OrderInfo memory orderInfo
    )
        private
        returns (Types.AssetAmount memory)
    {
        uint256 fee = orderInfo.tradeArgs.price.getPartial(orderInfo.tradeArgs.fee, PRICE_BASE);
        uint256 adjustedPrice = (isBuy(orderInfo.order) == orderInfo.tradeArgs.isNegativeFee)
            ? orderInfo.tradeArgs.price.sub(fee)
            : orderInfo.tradeArgs.price.add(fee);

        uint256 outputAmount;
        uint256 fillAmount;
        if (orderInfo.order.quoteMarket == inputMarketId) {
            outputAmount = inputWei.value.getPartial(PRICE_BASE, adjustedPrice);
            fillAmount = outputAmount;
        } else {
            assert(orderInfo.order.quoteMarket == outputMarketId);
            outputAmount = inputWei.value.getPartial(adjustedPrice, PRICE_BASE);
            fillAmount = inputWei.value;
        }

        updateFilledAmount(orderInfo, fillAmount);

        return Types.AssetAmount({
            sign: !inputWei.sign,
            denomination: Types.AssetDenomination.Wei,
            ref: Types.AssetReference.Delta,
            value: outputAmount
        });
    }

    /**
     * Increases the stored filled amount of the order by fillAmount.
     * Returns the new total filled amount.
     */
    function updateFilledAmount(
        OrderInfo memory orderInfo,
        uint256 fillAmount
    )
        private
    {
        uint256 oldFilledAmount = g_filledAmount[orderInfo.orderHash];
        uint256 totalFilledAmount = oldFilledAmount.add(fillAmount);
        Require.that(
            totalFilledAmount <= orderInfo.order.amount,
            FILE,
            "Cannot overfill order",
            orderInfo.orderHash,
            oldFilledAmount,
            fillAmount
        );

        g_filledAmount[orderInfo.orderHash] = totalFilledAmount;

        emit LogCanonicalOrderFilled(
            orderInfo.orderHash,
            orderInfo.order.makerAccountOwner,
            fillAmount,
            totalFilledAmount,
            orderInfo.tradeArgs.price,
            orderInfo.tradeArgs.fee,
            orderInfo.tradeArgs.isNegativeFee
        );
    }

    /**
     * Returns the current price of baseMarket divided by the current price of quoteMarket. This
     * value is multiplied by 10^18.
     */
    function getCurrentPrice(
        uint256 baseMarket,
        uint256 quoteMarket
    )
        private
        view
        returns (uint256)
    {
        Monetary.Price memory basePrice = SOLO_MARGIN.getMarketPrice(baseMarket);
        Monetary.Price memory quotePrice = SOLO_MARGIN.getMarketPrice(quoteMarket);
        return basePrice.value.mul(PRICE_BASE).div(quotePrice.value);
    }

    /**
     * Parses the order, verifies that it is not expired or canceled, and verifies the signature.
     */
    function getOrderAndValidateSignature(
        bytes memory data
    )
        private
        returns (OrderInfo memory)
    {
        Require.that(
            (
                data.length == NUM_ORDER_BYTES ||
                data.length == NUM_ORDER_BYTES + NUM_SIGNATURE_BYTES
            ),
            FILE,
            "Cannot parse order from data"
        );

        // load orderInfo from calldata
        OrderInfo memory orderInfo;
        (
            orderInfo.order,
            orderInfo.tradeArgs
        ) = abi.decode(data, (Order, TradeArgs));

        // load tradeArgs from storage if price is zero
        if (orderInfo.tradeArgs.price == 0) {
            orderInfo.tradeArgs = g_tradeArgs;
            g_tradeArgs = TradeArgs({
                price: 0,
                fee: 0,
                isNegativeFee: false
            });
        }
        Require.that(
            orderInfo.tradeArgs.price != 0,
            FILE,
            "TradeArgs loaded price is zero"
        );

        orderInfo.orderHash = getOrderHash(orderInfo.order);
        OrderStatus orderStatus = g_status[orderInfo.orderHash];

        // verify valid signature or is pre-approved
        if (orderStatus == OrderStatus.Null) {
            bytes memory signature = parseSignature(data);
            address signer = TypedSignature.recover(orderInfo.orderHash, signature);
            Require.that(
                orderInfo.order.makerAccountOwner == signer,
                FILE,
                "Order invalid signature",
                orderInfo.orderHash
            );
        } else {
            Require.that(
                orderStatus != OrderStatus.Canceled,
                FILE,
                "Order canceled",
                orderInfo.orderHash
            );
            assert(orderStatus == OrderStatus.Approved);
        }

        // verify price
        TradeArgs memory tradeArgs = orderInfo.tradeArgs;
        bool validPrice = isBuy(orderInfo.order)
            ? tradeArgs.price <= orderInfo.order.limitPrice
            : tradeArgs.price >= orderInfo.order.limitPrice;
        Require.that(
            validPrice,
            FILE,
            "Fill invalid price"
        );

        // verify fee
        bool validFee = isNegativeFee(orderInfo.order)
            ? (tradeArgs.fee >= orderInfo.order.limitFee) && tradeArgs.isNegativeFee
            : (tradeArgs.fee <= orderInfo.order.limitFee) || tradeArgs.isNegativeFee;
        Require.that(
            validFee,
            FILE,
            "Fill invalid fee"
        );

        return orderInfo;
    }

    // ============ Private Parsing Functions ============

    /**
     * Returns the EIP712 hash of an order.
     */
    function getOrderHash(
        Order memory order
    )
        private
        view
        returns (bytes32)
    {
        // compute the overall signed struct hash
        /* solium-disable-next-line indentation */
        bytes32 structHash = keccak256(abi.encode(
            EIP712_ORDER_STRUCT_SCHEMA_HASH,
            order
        ));

        // compute eip712 compliant hash
        /* solium-disable-next-line indentation */
        return keccak256(abi.encodePacked(
            EIP191_HEADER,
            EIP712_DOMAIN_HASH,
            structHash
        ));
    }

    /**
     * Parses out a signature from call data.
     */
    function parseSignature(
        bytes memory data
    )
        private
        pure
        returns (bytes memory)
    {
        Require.that(
            data.length == NUM_ORDER_BYTES + NUM_SIGNATURE_BYTES,
            FILE,
            "Cannot parse signature from data"
        );

        bytes memory signature = new bytes(NUM_SIGNATURE_BYTES);

        uint256 sigOffset = NUM_ORDER_BYTES;
        /* solium-disable-next-line security/no-inline-assembly */
        assembly {
            let sigStart := add(data, sigOffset)
            mstore(add(signature, 0x020), mload(add(sigStart, 0x20)))
            mstore(add(signature, 0x040), mload(add(sigStart, 0x40)))
            mstore(add(signature, 0x042), mload(add(sigStart, 0x42)))
        }

        return signature;
    }

    function isBuy(
        Order memory order
    )
        private
        pure
        returns (bool)
    {
        return (order.flags & IS_BUY_FLAG) != bytes32(0);
    }

    function isDecreaseOnly(
        Order memory order
    )
        private
        pure
        returns (bool)
    {
        return (order.flags & IS_DECREASE_ONLY_FLAG) != bytes32(0);
    }

    function isNegativeFee(
        Order memory order
    )
        private
        pure
        returns (bool)
    {
        return (order.flags & IS_NEGATIVE_FEE_FLAG) != bytes32(0);
    }
}