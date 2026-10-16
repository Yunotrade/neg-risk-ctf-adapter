// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {FeeFill, Order, Side, SignatureType} from "../../../lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";
import {ITradingEE} from "../../../lib/ctf-exchange/src/exchange/interfaces/ITrading.sol";

import {IConditionalTokens, ICTFExchange, IERC20, INegRiskAdapter} from "../../interfaces/index.sol";
import {NegRiskCtfExchangeTestHelper} from "./NegRiskCtfExchangeTestHelper.sol";

interface INegRiskBatchExchange is ITradingEE {
    function hashOrder(Order memory order) external view returns (bytes32);

    function matchOrdersWithFees(
        Order memory takerOrder,
        Order[] memory makerOrders,
        FeeFill memory takerFill,
        FeeFill[] memory makerFills
    ) external;

    function matchOrdersWithFeesBatch(
        Order memory takerOrder,
        Order[][] memory makerOrders,
        FeeFill[] memory takerFills,
        FeeFill[][] memory makerFills
    ) external;

    function setFeeRecipient(address recipient) external;

    function enableV11Only() external;
}

contract NegRiskMatchOrdersWithFeesBatchTest is NegRiskCtfExchangeTestHelper {
    uint256 internal constant Q_MINT = 5_747_126;
    uint256 internal constant TAKER_MINT_SLICE = 4_999_999;
    uint256 internal constant MAKER_MINT_SLICE = 747_127;
    uint256 internal constant Q_COMP = 10_000_001;
    uint256 internal constant COMP_SLICE = 4_000_001;
    uint256 internal constant COMP_LIMIT_COLLATERAL = 4_000_000;
    uint256 internal constant TAKER_LIMIT_COLLATERAL = 13_700_001;
    uint256 internal constant PI_MINT = 87e16;
    uint256 internal constant PI_COMP = 4e17;
    uint256 internal constant SELL_SHARES = 20_000_000;
    uint256 internal constant SELL_COLLATERAL = 8_000_000;
    uint256 internal constant LEG_SHARES = 10_000_000;
    uint256 internal constant LEG_BUY_COLLATERAL = 4_000_000;
    uint256 internal constant LEG_MERGE_COLLATERAL = 6_000_000;

    address internal feeRecipient;

    function setUp() public {
        marketId = INegRiskAdapter(negRiskAdapter).prepareMarket(0, "batch_market");
        questionId = INegRiskAdapter(negRiskAdapter).prepareQuestion(marketId, "batch_question");
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

    function test_negRisk_batch_complementaryThenMint() public {
        _fundBuyer(alice.addr, COMP_SLICE + TAKER_MINT_SLICE);
        _fundBuyer(carly.addr, MAKER_MINT_SLICE);
        _fundOutcome(brian.addr, yesPositionId, Q_COMP);
        _approveOutcomeSeller(brian.addr);

        (Order memory taker, Order[] memory compMakers, FeeFill memory compTaker, FeeFill[] memory compFills,
            Order[] memory mintMakers, FeeFill memory mintTaker, FeeFill[] memory mintFills) = _complementaryThenMint();

        uint256 aliceBefore = IERC20(usdc).balanceOf(alice.addr);
        uint256 brianBefore = IERC20(usdc).balanceOf(brian.addr);
        uint256 carlyBefore = IERC20(usdc).balanceOf(carly.addr);
        _batch(taker, compMakers, compTaker, compFills, mintMakers, mintTaker, mintFills);

        uint256 aliceAfter = IERC20(usdc).balanceOf(alice.addr);
        uint256 brianAfter = IERC20(usdc).balanceOf(brian.addr);
        uint256 carlyAfter = IERC20(usdc).balanceOf(carly.addr);
        assertEq(aliceBefore - aliceAfter, COMP_SLICE + TAKER_MINT_SLICE, "taker debit");
        assertEq(brianAfter - brianBefore, COMP_SLICE, "seller credit");
        assertEq(carlyBefore - carlyAfter, MAKER_MINT_SLICE, "mint maker debit");
        assertEq(aliceBefore + brianBefore + carlyBefore - aliceAfter - brianAfter - carlyAfter, Q_MINT, "minted collateral");
        assertEq(IConditionalTokens(ctf).balanceOf(alice.addr, yesPositionId), Q_COMP + Q_MINT, "taker shares");
        assertEq(IConditionalTokens(ctf).balanceOf(carly.addr, noPositionId), Q_MINT, "mint shares");
        _assertNoExchangeResidual();
    }

    function test_negRisk_batch_sellComplementaryThenMerge() public {
        _fundOutcome(alice.addr, yesPositionId, SELL_SHARES);
        _fundOutcome(carly.addr, noPositionId, LEG_SHARES);
        _approveOutcomeSeller(alice.addr);
        _approveOutcomeSeller(carly.addr);
        _fundBuyer(brian.addr, LEG_BUY_COLLATERAL);

        (Order memory taker, Order[] memory compMakers, FeeFill memory compTaker, FeeFill[] memory compFills,
            Order[] memory mergeMakers, FeeFill memory mergeTaker, FeeFill[] memory mergeFills) = _sellThenMerge();
        uint256 snap = vm.snapshot();
        _batch(taker, compMakers, compTaker, compFills, mergeMakers, mergeTaker, mergeFills);
        assertEq(IConditionalTokens(ctf).balanceOf(alice.addr, yesPositionId), 0, "seller YES");
        assertEq(IConditionalTokens(ctf).balanceOf(brian.addr, yesPositionId), LEG_SHARES, "buyer YES");
        assertEq(IConditionalTokens(ctf).balanceOf(carly.addr, noPositionId), 0, "merge NO");
        _assertNoExchangeResidual();
        uint256 aliceAfter = IERC20(usdc).balanceOf(alice.addr);
        uint256 brianAfter = IERC20(usdc).balanceOf(brian.addr);
        uint256 carlyAfter = IERC20(usdc).balanceOf(carly.addr);
        uint256 aliceYes = IConditionalTokens(ctf).balanceOf(alice.addr, yesPositionId);
        uint256 brianYes = IConditionalTokens(ctf).balanceOf(brian.addr, yesPositionId);
        uint256 carlyNo = IConditionalTokens(ctf).balanceOf(carly.addr, noPositionId);
        vm.revertTo(snap);
        _matchOne(taker, compMakers, compTaker, compFills);
        _matchOne(taker, mergeMakers, mergeTaker, mergeFills);
        assertEq(IERC20(usdc).balanceOf(alice.addr), aliceAfter, "seller");
        assertEq(IERC20(usdc).balanceOf(brian.addr), brianAfter, "buyer");
        assertEq(IERC20(usdc).balanceOf(carly.addr), carlyAfter, "merge maker");
        assertEq(IConditionalTokens(ctf).balanceOf(alice.addr, yesPositionId), aliceYes, "seller YES");
        assertEq(IConditionalTokens(ctf).balanceOf(brian.addr, yesPositionId), brianYes, "buyer YES");
        assertEq(IConditionalTokens(ctf).balanceOf(carly.addr, noPositionId), carlyNo, "merge NO");
        _assertNoExchangeResidual();
    }

    function test_negRisk_batch_laterGroupRollsBack() public {
        _fundBuyer(alice.addr, COMP_SLICE + TAKER_MINT_SLICE);
        _fundOutcome(brian.addr, yesPositionId, Q_COMP);
        _approveOutcomeSeller(brian.addr);
        (Order memory taker, Order[] memory compMakers, FeeFill memory compTaker, FeeFill[] memory compFills,,,) =
            _complementaryThenMint();
        FeeFill memory mintTaker = FeeFill({q: Q_MINT, pi: PI_MINT, f: 0});
        Order[] memory badMakers = new Order[](1);
        badMakers[0] = _order(carly.privateKey, noPositionId, MAKER_MINT_SLICE, Q_MINT, Side.BUY, 9);
        FeeFill[] memory badFills = new FeeFill[](1);
        badFills[0] = FeeFill({q: Q_MINT, pi: PI_MINT + 1, f: 0});

        uint256 aliceBefore = IERC20(usdc).balanceOf(alice.addr);
        uint256 brianBefore = IERC20(usdc).balanceOf(brian.addr);
        vm.prank(operator.addr);
        vm.expectRevert(ITradingEE.MismatchedFillPrice.selector);
        _exchange().matchOrdersWithFeesBatch(
            taker, _groups(compMakers, badMakers), _fills(compTaker, mintTaker), _fillGroups(compFills, badFills)
        );
        assertEq(IERC20(usdc).balanceOf(alice.addr), aliceBefore, "taker unchanged");
        assertEq(IERC20(usdc).balanceOf(brian.addr), brianBefore, "maker unchanged");
        assertEq(IConditionalTokens(ctf).balanceOf(brian.addr, yesPositionId), Q_COMP, "shares unchanged");
        _assertNoExchangeResidual();
    }

    function _complementaryThenMint()
        internal
        view
        returns (
            Order memory taker,
            Order[] memory compMakers,
            FeeFill memory compTaker,
            FeeFill[] memory compFills,
            Order[] memory mintMakers,
            FeeFill memory mintTaker,
            FeeFill[] memory mintFills
        )
    {
        taker = _order(alice.privateKey, yesPositionId, TAKER_LIMIT_COLLATERAL, Q_COMP + Q_MINT, Side.BUY, 1);
        compMakers = new Order[](1);
        compMakers[0] = _order(brian.privateKey, yesPositionId, Q_COMP, COMP_LIMIT_COLLATERAL, Side.SELL, 2);
        compTaker = FeeFill({q: Q_COMP, pi: PI_COMP, f: 0});
        compFills = new FeeFill[](1);
        compFills[0] = compTaker;
        mintMakers = new Order[](1);
        mintMakers[0] = _order(carly.privateKey, noPositionId, MAKER_MINT_SLICE, Q_MINT, Side.BUY, 3);
        mintTaker = FeeFill({q: Q_MINT, pi: PI_MINT, f: 0});
        mintFills = new FeeFill[](1);
        mintFills[0] = mintTaker;
    }

    function _sellThenMerge()
        internal
        view
        returns (
            Order memory taker,
            Order[] memory compMakers,
            FeeFill memory compTaker,
            FeeFill[] memory compFills,
            Order[] memory mergeMakers,
            FeeFill memory mergeTaker,
            FeeFill[] memory mergeFills
        )
    {
        taker = _order(alice.privateKey, yesPositionId, SELL_SHARES, SELL_COLLATERAL, Side.SELL, 1);
        compMakers = new Order[](1);
        compMakers[0] = _order(brian.privateKey, yesPositionId, LEG_BUY_COLLATERAL, LEG_SHARES, Side.BUY, 6);
        compTaker = FeeFill({q: LEG_SHARES, pi: PI_COMP, f: 0});
        compFills = new FeeFill[](1);
        compFills[0] = compTaker;
        mergeMakers = new Order[](1);
        mergeMakers[0] = _order(carly.privateKey, noPositionId, LEG_SHARES, LEG_MERGE_COLLATERAL, Side.SELL, 7);
        mergeTaker = FeeFill({q: LEG_SHARES, pi: PI_COMP, f: 0});
        mergeFills = new FeeFill[](1);
        mergeFills[0] = mergeTaker;
    }

    function _batch(
        Order memory taker,
        Order[] memory makers0,
        FeeFill memory taker0,
        FeeFill[] memory fills0,
        Order[] memory makers1,
        FeeFill memory taker1,
        FeeFill[] memory fills1
    ) internal {
        vm.prank(operator.addr);
        _exchange().matchOrdersWithFeesBatch(
            taker, _groups(makers0, makers1), _fills(taker0, taker1), _fillGroups(fills0, fills1)
        );
    }

    function _matchOne(Order memory taker, Order[] memory makers, FeeFill memory takerFill, FeeFill[] memory fills)
        internal
    {
        vm.prank(operator.addr);
        _exchange().matchOrdersWithFees(taker, makers, takerFill, fills);
    }

    function _order(
        uint256 privateKey,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side,
        uint256 salt
    ) internal view returns (Order memory order) {
        address maker = vm.addr(privateKey);
        order = Order({
            salt: salt,
            maker: maker,
            signer: maker,
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: side,
            signatureType: SignatureType.EOA,
            signature: new bytes(0)
        });
        order.signature = _signMessage(privateKey, _exchange().hashOrder(order));
    }

    function _groups(Order[] memory a, Order[] memory b) internal pure returns (Order[][] memory groups) {
        groups = new Order[][](2);
        groups[0] = a;
        groups[1] = b;
    }

    function _fills(FeeFill memory a, FeeFill memory b) internal pure returns (FeeFill[] memory fills) {
        fills = new FeeFill[](2);
        fills[0] = a;
        fills[1] = b;
    }

    function _fillGroups(FeeFill[] memory a, FeeFill[] memory b) internal pure returns (FeeFill[][] memory groups) {
        groups = new FeeFill[][](2);
        groups[0] = a;
        groups[1] = b;
    }

    function _fundOutcome(address recipient, uint256 positionId, uint256 amount) internal {
        vm.startPrank(admin.addr);
        _dealERC20(usdc, admin.addr, amount);
        IERC20(usdc).approve(negRiskAdapter, amount);
        INegRiskAdapter(negRiskAdapter).splitPosition(usdc, bytes32(0), conditionId, partition, amount);
        IConditionalTokens(ctf).safeTransferFrom(admin.addr, recipient, positionId, amount, "");
        vm.stopPrank();
    }

    function _exchange() internal view returns (INegRiskBatchExchange) {
        return INegRiskBatchExchange(negRiskCtfExchange);
    }
}
