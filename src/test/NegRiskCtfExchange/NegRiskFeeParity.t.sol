// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {GrossBudgetFeeMath} from "../../../lib/ctf-exchange/src/exchange/libraries/GrossBudgetFeeMath.sol";
import {FeeFill, Order, Side, SignatureType} from "../../../lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";

import {IConditionalTokens, ICTFExchange, IERC20, INegRiskAdapter} from "../../interfaces/index.sol";
import {NegRiskCtfExchangeTestHelper} from "./NegRiskCtfExchangeTestHelper.sol";

interface INegRiskFeeExchange {
    error FeeRecipientAlreadySet();

    function hashOrder(Order memory order) external view returns (bytes32);

    function matchOrdersWithFees(
        Order memory takerOrder,
        Order[] memory makerOrders,
        FeeFill memory takerFill,
        FeeFill[] memory makerFills
    ) external;

    function setFeeRecipient(address recipient) external;

    function enableV11Only() external;
}

contract NegRiskFeeParityTest is NegRiskCtfExchangeTestHelper {
    uint256 internal constant S = 1e18;
    uint256 internal constant Q = 100_000_003;
    uint256 internal constant PI = 4e17;
    uint256 internal constant F = 1_000_000;
    uint256 internal constant FEE_RATE_BPS = 1_000;
    address internal feeRecipient;

    function setUp() public {
        marketId = INegRiskAdapter(negRiskAdapter).prepareMarket(0, "fee_parity_market");
        questionId = INegRiskAdapter(negRiskAdapter).prepareQuestion(marketId, "fee_parity_question");
        conditionId = INegRiskAdapter(negRiskAdapter).getConditionId(questionId);

        yesPositionId = INegRiskAdapter(negRiskAdapter).getPositionId(questionId, true);
        noPositionId = INegRiskAdapter(negRiskAdapter).getPositionId(questionId, false);

        feeRecipient = makeAddr("feeRecipient");
        vm.startPrank(admin.addr);
        ICTFExchange(negRiskCtfExchange).registerToken(yesPositionId, noPositionId, conditionId);
        _exchange().setFeeRecipient(feeRecipient);
        _exchange().enableV11Only();
        vm.stopPrank();
    }

    function test_NegRisk_matchOrdersWithFees_complementary_buyNPlusF_sellPMinusF() public {
        uint256 n = GrossBudgetFeeMath.executionCollateral(Q, PI, S);
        _fundBuyer(alice.addr, n + F);
        _fundOutcome(brian.addr, yesPositionId, Q);
        _approveOutcomeSeller(brian.addr);

        Order memory buy = _createFeeOrder(alice.privateKey, yesPositionId, n + F, Q, Side.BUY);
        Order memory sell = _createFeeOrder(brian.privateKey, yesPositionId, Q, n, Side.SELL);

        uint256 aliceCollateralBefore = IERC20(usdc).balanceOf(alice.addr);
        uint256 brianCollateralBefore = IERC20(usdc).balanceOf(brian.addr);
        uint256 operatorCollateralBefore = IERC20(usdc).balanceOf(operator.addr);
        uint256 feeRecipientCollateralBefore = IERC20(usdc).balanceOf(feeRecipient);

        _match(buy, sell);

        assertEq(IERC20(usdc).balanceOf(alice.addr), aliceCollateralBefore - (n + F), "BUY must debit N+f");
        assertEq(IERC20(usdc).balanceOf(brian.addr), brianCollateralBefore + (n - F), "SELL must receive P-f");
        assertEq(IERC20(usdc).balanceOf(operator.addr), operatorCollateralBefore, "operator must not custody fees");
        assertEq(IERC20(usdc).balanceOf(feeRecipient), feeRecipientCollateralBefore + (2 * F), "fees");
        assertEq(IConditionalTokens(ctf).balanceOf(alice.addr, yesPositionId), Q, "buyer shares");
        assertEq(IConditionalTokens(ctf).balanceOf(brian.addr, yesPositionId), 0, "seller shares");
        _assertNoExchangeResidual();
    }

    function test_NegRisk_feeRecipientCannotBeReassigned() public {
        vm.prank(admin.addr);
        vm.expectRevert(INegRiskFeeExchange.FeeRecipientAlreadySet.selector);
        _exchange().setFeeRecipient(makeAddr("replacementFeeRecipient"));
    }

    function test_NegRisk_matchOrdersWithFees_mint_exactComplementAndBuyNPlusF() public {
        (uint256 nYes, uint256 nNo) = GrossBudgetFeeMath.complementNotionals(Q, PI, S);
        assertEq(nYes + nNo, Q, "N_yes + N_no must equal q");

        _fundBuyer(alice.addr, nYes + F);
        _fundBuyer(brian.addr, nNo + F);

        Order memory yesBuy = _createFeeOrder(alice.privateKey, yesPositionId, nYes + F, Q, Side.BUY);
        Order memory noBuy = _createFeeOrder(brian.privateKey, noPositionId, nNo + F, Q, Side.BUY);

        uint256 aliceCollateralBefore = IERC20(usdc).balanceOf(alice.addr);
        uint256 brianCollateralBefore = IERC20(usdc).balanceOf(brian.addr);
        uint256 operatorCollateralBefore = IERC20(usdc).balanceOf(operator.addr);
        uint256 feeRecipientCollateralBefore = IERC20(usdc).balanceOf(feeRecipient);

        _match(yesBuy, noBuy);

        assertEq(IERC20(usdc).balanceOf(alice.addr), aliceCollateralBefore - (nYes + F), "YES BUY N+f");
        assertEq(IERC20(usdc).balanceOf(brian.addr), brianCollateralBefore - (nNo + F), "NO BUY N+f");
        assertEq(IERC20(usdc).balanceOf(operator.addr), operatorCollateralBefore, "operator must not custody fees");
        assertEq(IERC20(usdc).balanceOf(feeRecipient), feeRecipientCollateralBefore + (2 * F), "fees");
        assertEq(IConditionalTokens(ctf).balanceOf(alice.addr, yesPositionId), Q, "YES shares");
        assertEq(IConditionalTokens(ctf).balanceOf(brian.addr, noPositionId), Q, "NO shares");
        _assertNoExchangeResidual();
    }

    function test_NegRisk_matchOrdersWithFees_merge_exactComplementAndSellPMinusF() public {
        (uint256 pYes, uint256 pNo) = GrossBudgetFeeMath.complementNotionals(Q, PI, S);
        assertEq(pYes + pNo, Q, "P_yes + P_no must equal q");

        _fundCompleteSet(alice.addr, brian.addr, Q);
        _approveOutcomeSeller(alice.addr);
        _approveOutcomeSeller(brian.addr);

        Order memory yesSell = _createFeeOrder(alice.privateKey, yesPositionId, Q, pYes, Side.SELL);
        Order memory noSell = _createFeeOrder(brian.privateKey, noPositionId, Q, pNo, Side.SELL);

        uint256 aliceCollateralBefore = IERC20(usdc).balanceOf(alice.addr);
        uint256 brianCollateralBefore = IERC20(usdc).balanceOf(brian.addr);
        uint256 operatorCollateralBefore = IERC20(usdc).balanceOf(operator.addr);
        uint256 feeRecipientCollateralBefore = IERC20(usdc).balanceOf(feeRecipient);

        _match(yesSell, noSell);

        assertEq(IERC20(usdc).balanceOf(alice.addr), aliceCollateralBefore + (pYes - F), "YES SELL P-f");
        assertEq(IERC20(usdc).balanceOf(brian.addr), brianCollateralBefore + (pNo - F), "NO SELL P-f");
        assertEq(IERC20(usdc).balanceOf(operator.addr), operatorCollateralBefore, "operator must not custody fees");
        assertEq(IERC20(usdc).balanceOf(feeRecipient), feeRecipientCollateralBefore + (2 * F), "fees");
        assertEq(IConditionalTokens(ctf).balanceOf(alice.addr, yesPositionId), 0, "YES sold");
        assertEq(IConditionalTokens(ctf).balanceOf(brian.addr, noPositionId), 0, "NO sold");
        _assertNoExchangeResidual();
    }

    function _createFeeOrder(uint256 privateKey, uint256 tokenId, uint256 makerAmount, uint256 takerAmount, Side side)
        internal
        view
        returns (Order memory order)
    {
        address maker = vm.addr(privateKey);
        order = Order({
            salt: 1,
            maker: maker,
            signer: maker,
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: FEE_RATE_BPS,
            side: side,
            signatureType: SignatureType.EOA,
            signature: new bytes(0)
        });
        order.signature = _signMessage(privateKey, _exchange().hashOrder(order));
    }

    function _match(Order memory takerOrder, Order memory makerOrder) internal {
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        FeeFill memory takerFill = FeeFill({q: Q, pi: PI, f: F});
        FeeFill[] memory makerFills = new FeeFill[](1);
        makerFills[0] = takerFill;

        vm.prank(operator.addr);
        _exchange().matchOrdersWithFees(takerOrder, makerOrders, takerFill, makerFills);
    }

    function _fundBuyer(address buyer, uint256 amount) internal {
        _dealERC20(usdc, buyer, amount);
        vm.prank(buyer);
        IERC20(usdc).approve(negRiskCtfExchange, type(uint256).max);
    }

    function _fundOutcome(address recipient, uint256 positionId, uint256 amount) internal {
        vm.startPrank(carly.addr);
        _dealERC20(usdc, carly.addr, amount);
        IERC20(usdc).approve(negRiskAdapter, amount);
        INegRiskAdapter(negRiskAdapter).splitPosition(usdc, bytes32(0), conditionId, partition, amount);
        IConditionalTokens(ctf).safeTransferFrom(carly.addr, recipient, positionId, amount, "");
        vm.stopPrank();
    }

    function _fundCompleteSet(address yesRecipient, address noRecipient, uint256 amount) internal {
        vm.startPrank(carly.addr);
        _dealERC20(usdc, carly.addr, amount);
        IERC20(usdc).approve(negRiskAdapter, amount);
        INegRiskAdapter(negRiskAdapter).splitPosition(usdc, bytes32(0), conditionId, partition, amount);
        IConditionalTokens(ctf).safeTransferFrom(carly.addr, yesRecipient, yesPositionId, amount, "");
        IConditionalTokens(ctf).safeTransferFrom(carly.addr, noRecipient, noPositionId, amount, "");
        vm.stopPrank();
    }

    function _approveOutcomeSeller(address seller) internal {
        vm.startPrank(seller);
        IConditionalTokens(ctf).setApprovalForAll(negRiskCtfExchange, true);
        IConditionalTokens(ctf).setApprovalForAll(negRiskAdapter, true);
        vm.stopPrank();
    }

    function _assertNoExchangeResidual() internal view {
        assertEq(IERC20(usdc).balanceOf(negRiskCtfExchange), 0, "collateral residual");
        assertEq(IConditionalTokens(ctf).balanceOf(negRiskCtfExchange, yesPositionId), 0, "YES residual");
        assertEq(IConditionalTokens(ctf).balanceOf(negRiskCtfExchange, noPositionId), 0, "NO residual");
    }

    function _exchange() internal view returns (INegRiskFeeExchange) {
        return INegRiskFeeExchange(negRiskCtfExchange);
    }
}
