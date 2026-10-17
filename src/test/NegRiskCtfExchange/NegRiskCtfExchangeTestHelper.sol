// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console, Test, Vm} from "../../../lib/forge-std/src/Test.sol";
import {Side, SignatureType} from "../../../lib/ctf-exchange/src/exchange/libraries/OrderStructs.sol";
import {NegRiskAdapter} from "../../NegRiskAdapter.sol";
import {IConditionalTokens, ICTFExchange, IERC20} from "../../interfaces/index.sol";
import {AddressLib} from "../../dev/libraries/AddressLib.sol";
import {DeployLib} from "../../dev/libraries/DeployLib.sol";
import {OrderHelper} from "../../dev/OrderHelper.sol";
import {StorageHelper} from "../../dev/StorageHelper.sol";
import {USDC} from "../mock/USDC.sol";

contract NegRiskCtfExchangeTestHelper is Test, OrderHelper, StorageHelper {
    address immutable ctf;
    address immutable negRiskAdapter;
    address immutable negRiskCtfExchange;
    address immutable usdc;

    Vm.Wallet alice;
    Vm.Wallet brian;
    Vm.Wallet carly;
    Vm.Wallet admin;
    Vm.Wallet operator;

    uint256[] partition;

    bytes32 marketId;
    bytes32 questionId;
    bytes32 conditionId;

    uint256 yesPositionId;
    uint256 noPositionId;

    constructor() {
        admin = vm.createWallet("admin");
        operator = vm.createWallet("operator");

        alice = vm.createWallet("alice");
        brian = vm.createWallet("brian");
        carly = vm.createWallet("carly");

        address vault = vm.createWallet("vault").addr;

        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.startPrank(admin.addr);

        ctf = DeployLib.deployConditionalTokens();
        usdc = address(new USDC());

        negRiskAdapter = address(new NegRiskAdapter(ctf, usdc, vault));
        negRiskCtfExchange = DeployLib.deployNegRiskCtfExchange({
            _collateral: usdc,
            _ctf: ctf,
            _negRiskAdapter: negRiskAdapter,
            _proxyFactory: address(0),
            _safeFactory: address(0)
        });

        // allow negRiskCtfExchange to transfer using the NegRiskAdapter
        NegRiskAdapter(negRiskAdapter).addAdmin(negRiskCtfExchange);
        // renounce address(this) as admin
        NegRiskAdapter(negRiskAdapter).renounceAdmin();

        // set operator
        ICTFExchange(negRiskCtfExchange).addOperator(operator.addr);

        vm.stopPrank();
    }

    function _fundBuyer(address buyer, uint256 amount) internal {
        _dealERC20(usdc, buyer, amount);
        vm.prank(buyer);
        IERC20(usdc).approve(negRiskCtfExchange, type(uint256).max);
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
}
