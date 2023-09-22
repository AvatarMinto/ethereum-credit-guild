// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";

contract ProfitManagerUnitTest is Test {
    address private governor = address(1);
    Core private core;
    ProfitManager private profitManager;
    CreditToken credit;
    GuildToken guild;
    address constant alice = address(0x616c696365);
    address constant bob = address(0xB0B);
    address constant gauge1 = address(0xDEAD);
    address constant gauge2 = address(0xBEEF);
    address constant gauge3 = address(0x3333);

    uint256 public issuance; // for mocked behavior

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();
        profitManager = new ProfitManager(address(core));
        credit = new CreditToken(address(core));
        guild = new GuildToken(address(core), address(profitManager), address(credit));

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(guild), "guild");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(gauge1, "gauge1");
        vm.label(gauge2, "gauge2");
        vm.label(gauge3, "gauge3");

        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));

        // non-zero CREDIT circulating (for notify gauge losses)
        credit.mint(address(this), 100e18);
        credit.enterRebase();

        // initialize profitManager
        assertEq(profitManager.credit(), address(0));
        assertEq(profitManager.guild(), address(0));
        profitManager.initializeReferences(address(credit), address(guild));

        core.renounceRole(CoreRoles.GOVERNOR, address(this));
    }

    /*///////////////////////////////////////////////////////////////
                        TEST INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function testInitialState() public {
        assertEq(address(profitManager.core()), address(core));
        assertEq(profitManager.credit(), address(credit));
        assertEq(profitManager.guild(), address(guild));
        assertEq(profitManager.surplusBuffer(), 0);
        assertEq(profitManager.creditMultiplier(), 1e18);
    }

    function testInitializeReferences() public {
        ProfitManager pm2 = new ProfitManager(address(core));
        assertEq(pm2.credit(), address(0));
        assertEq(pm2.guild(), address(0));
        vm.expectRevert("UNAUTHORIZED");
        pm2.initializeReferences(address(credit), address(guild));
        vm.prank(governor);
        pm2.initializeReferences(address(credit), address(guild));
        assertEq(pm2.credit(), address(credit));
        assertEq(pm2.guild(), address(guild));
        vm.expectRevert();
        vm.prank(governor);
        pm2.initializeReferences(address(credit), address(guild));
    }

    function testCreditMultiplier() public {
        // grant roles to test contract
        vm.startPrank(governor);
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        vm.stopPrank();

        // initial state
        // 100 CREDIT circulating (assuming backed by >= 100 USD)
        assertEq(profitManager.creditMultiplier(), 1e18);
        assertEq(credit.totalSupply(), 100e18);

        // apply a loss (1)
        // 30 CREDIT of loans completely default (~30 USD loss)
        profitManager.notifyPnL(address(this), -30e18);
        assertEq(profitManager.creditMultiplier(), 0.7e18); // 30% discounted

        // apply a loss (2)
        // 20 CREDIT of loans completely default (~14 USD loss because CREDIT now worth 0.7 USD)
        profitManager.notifyPnL(address(this), -20e18);
        assertEq(profitManager.creditMultiplier(), 0.56e18); // 56% discounted

        // apply a gain on an existing loan
        credit.mint(address(profitManager), 70e18);
        profitManager.notifyPnL(address(this), 70e18);
        assertEq(profitManager.creditMultiplier(), 0.56e18); // unchanged, does not go back up

        // new CREDIT is minted
        // new loans worth 830 CREDIT are opened
        credit.mint(address(this), 830e18);
        assertEq(credit.totalSupply(), 1000e18);

        // apply a loss (3)
        // 500 CREDIT of loans completely default
        profitManager.notifyPnL(address(this), -500e18);
        assertEq(profitManager.creditMultiplier(), 0.28e18); // half of previous value because half the supply defaulted
    }

    function testSetProfitSharingConfig() public {
        (
            uint256 surplusBufferSplit,
            uint256 creditSplit,
            uint256 guildSplit,
            uint256 otherSplit,
            address otherRecipient
        ) = profitManager.getProfitSharingConfig();
        assertEq(surplusBufferSplit, 0);
        assertEq(creditSplit, 1e18);
        assertEq(guildSplit, 0);
        assertEq(otherSplit, 0);
        assertEq(otherRecipient, address(0));

        // revert if not governor
        vm.expectRevert("UNAUTHORIZED");
        profitManager.setProfitSharingConfig(
            0.05e18, // surplusBufferSplit
            0.8e18, // creditSplit
            0.05e18, // guildSplit
            0.1e18, // otherSplit
            address(this) // otherRecipient
        );

        // provides no 'other' recipient, but non-zero 'other' split
        vm.expectRevert("GuildToken: invalid config");
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0.05e18, // surplusBufferSplit
            0.8e18, // creditSplit
            0.05e18, // guildSplit
            0.1e18, // otherSplit
            address(0) // otherRecipient
        );

        // provides 'other' recipient, but zero 'other' split
        vm.expectRevert("GuildToken: invalid config");
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0.15e18, // surplusBufferSplit
            0.8e18, // creditSplit
            0.05e18, // guildSplit
            0, // otherSplit
            address(this) // otherRecipient
        );

        // sum != 100%
        vm.expectRevert("GuildToken: invalid config");
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0.1e18, // surplusBufferSplit
            0.8e18, // creditSplit
            0.1e18, // guildSplit
            0.1e18, // otherSplit
            address(this) // otherRecipient
        );

        // ok
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0.05e18, // surplusBufferSplit
            0.8e18, // creditSplit
            0.05e18, // guildSplit
            0.1e18, // otherSplit
            address(this) // otherRecipient
        );

        (
            surplusBufferSplit,
            creditSplit,
            guildSplit,
            otherSplit,
            otherRecipient
        ) = profitManager.getProfitSharingConfig();
        assertEq(surplusBufferSplit, 0.05e18);
        assertEq(creditSplit, 0.8e18);
        assertEq(guildSplit, 0.05e18);
        assertEq(otherSplit, 0.1e18);
        assertEq(otherRecipient, address(this));
    }

    function testProfitDistribution() public {
        // grant roles to test contract
        vm.startPrank(governor);
        core.grantRole(CoreRoles.GOVERNOR, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        vm.stopPrank();

        // setup
        // 50-50 profit split between GUILD & CREDIT
        // 150 CREDIT circulating (100 rebasing on test contract, 50 non rebasing on alice)
        // 550 GUILD, 500 voting in gauges :
        //   - 50 on gauge1 (alice)
        //   - 250 on gauge2 (50 alice, 200 bob)
        //   - 200 on gauge3 (200 bob)
        credit.mint(alice, 50e18);
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0, // surplusBufferSplit
            0.5e18, // creditSplit
            0.5e18, // guildSplit
            0, // otherSplit
            address(0) // otherRecipient
        );
        guild.setMaxGauges(3);
        guild.addGauge(1, gauge1);
        guild.addGauge(1, gauge2);
        guild.addGauge(1, gauge3);
        guild.mint(alice, 150e18);
        guild.mint(bob, 400e18);
        vm.startPrank(alice);
        guild.incrementGauge(gauge1, 50e18);
        guild.incrementGauge(gauge2, 50e18);
        vm.stopPrank();
        vm.startPrank(bob);
        guild.incrementGauge(gauge2, 200e18);
        guild.incrementGauge(gauge3, 200e18);
        vm.stopPrank();

        // simulate 20 profit on gauge1
        // 10 goes to alice (guild voting)
        // 10 goes to test (rebasing credit)
        credit.mint(address(profitManager), 20e18);
        profitManager.notifyPnL(gauge1, 20e18);
        assertEq(profitManager.claimRewards(alice), 10e18);
        assertEq(profitManager.claimRewards(bob), 0);
        assertEq(credit.balanceOf(address(this)), 110e18);
    
        // simulate 50 profit on gauge2
        // 5 goes to alice (guild voting)
        // 20 goes to bob (guild voting)
        // 25 goes to test (rebasing credit)
        credit.mint(address(profitManager), 50e18);
        profitManager.notifyPnL(gauge2, 50e18);
        assertEq(profitManager.claimRewards(alice), 5e18);
        assertEq(profitManager.claimRewards(bob), 20e18);
        assertEq(credit.balanceOf(address(this)), 135e18);

        // check the balances are as expected
        assertEq(credit.balanceOf(alice), 50e18 + 15e18);
        assertEq(credit.balanceOf(bob), 20e18);
        assertEq(credit.totalSupply(), 220e18);

        // simulate 100 profit on gauge2 + 100 profit on gauge3
        // 10 goes to alice (10 guild voting on gauge2)
        // 90 goes to bob (40 guild voting on gauge2 + 50 guild voting on gauge3)
        // 100 goes to test (50+50 for rebasing credit)
        credit.mint(address(profitManager), 100e18);
        profitManager.notifyPnL(gauge2, 100e18);
        credit.mint(address(profitManager), 100e18);
        profitManager.notifyPnL(gauge3, 100e18);
        //assertEq(profitManager.claimRewards(alice), 10e18);
        vm.prank(alice);
        guild.incrementGauge(gauge2, 50e18); // should claim her 10 pending rewards in gauge2
        assertEq(profitManager.claimRewards(bob), 90e18);
        assertEq(credit.balanceOf(address(this)), 235e18);

        // check the balances are as expected
        assertEq(credit.balanceOf(alice), 50e18 + 15e18 + 10e18);
        assertEq(credit.balanceOf(bob), 20e18 + 90e18);
        assertEq(credit.totalSupply(), 220e18 + 200e18);

        // gauge2 votes are now 100 alice, 200 bob
        // simulate 300 profit on gauge2
        // 50 goes to alice (guild voting)
        // 100 goes to bob (guild voting)
        // 150 goes to test (rebasing credit)
        credit.mint(address(profitManager), 300e18);
        profitManager.notifyPnL(gauge2, 300e18);
        //assertEq(profitManager.claimRewards(alice), 50e18);
        vm.prank(alice);
        guild.decrementGauge(gauge2, 100e18); // should claim her 50 pending rewards in gauge2
        assertEq(profitManager.claimRewards(bob), 100e18);
        assertEq(credit.balanceOf(address(this)), 235e18 + 150e18);

        // check the balances are as expected
        assertEq(credit.balanceOf(alice), 50e18 + 15e18 + 10e18 + 50e18);
        assertEq(credit.balanceOf(bob), 20e18 + 90e18 + 100e18);
        assertEq(credit.totalSupply(), 220e18 + 200e18 + 300e18);

        // change all fees go to alice
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0, // surplusBufferSplit
            0, // creditSplit
            0, // guildSplit
            1e18, // otherSplit
            alice // otherRecipient
        );

        // simulate 100 profit on gauge3
        credit.mint(address(profitManager), 100e18);
        profitManager.notifyPnL(gauge3, 100e18);

        assertEq(credit.balanceOf(alice), 50e18 + 15e18 + 10e18 + 50e18 + 100e18);
    }

    function testGetPendingRewards() public {
        // grant roles to test contract
        vm.startPrank(governor);
        core.grantRole(CoreRoles.GOVERNOR, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        vm.stopPrank();

        // setup
        // 50-50 profit split between GUILD & CREDIT
        // 150 CREDIT circulating (100 rebasing on test contract, 50 non rebasing on alice)
        // 550 GUILD, 500 voting in gauges :
        //   - 50 on gauge1 (alice)
        //   - 250 on gauge2 (50 alice, 200 bob)
        //   - 200 on gauge3 (200 bob)
        credit.mint(alice, 50e18);
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            0, // surplusBufferSplit
            0.5e18, // creditSplit
            0.5e18, // guildSplit
            0, // otherSplit
            address(0) // otherRecipient
        );
        guild.setMaxGauges(3);
        guild.addGauge(1, gauge1);
        guild.addGauge(1, gauge2);
        guild.addGauge(1, gauge3);
        guild.mint(alice, 150e18);
        guild.mint(bob, 400e18);
        vm.startPrank(alice);
        guild.incrementGauge(gauge1, 50e18);
        guild.incrementGauge(gauge2, 50e18);
        vm.stopPrank();
        vm.startPrank(bob);
        guild.incrementGauge(gauge2, 200e18);
        guild.incrementGauge(gauge3, 200e18);
        vm.stopPrank();

        // simulate 20 profit on gauge1
        // 10 goes to alice (guild voting)
        // 10 goes to test (rebasing credit)
        credit.mint(address(profitManager), 20e18);
        profitManager.notifyPnL(gauge1, 20e18);

        // check alice pending rewards
        (address[] memory aliceGauges, uint256[] memory aliceGaugeRewards, uint256 aliceTotalRewards) = profitManager.getPendingRewards(alice);
        assertEq(aliceGauges.length, 2);
        assertEq(aliceGauges[0], gauge1);
        assertEq(aliceGauges[1], gauge2);
        assertEq(aliceGaugeRewards.length, 2);
        assertEq(aliceGaugeRewards[0], 10e18);
        assertEq(aliceGaugeRewards[1], 0);
        assertEq(aliceTotalRewards, 10e18);
        assertEq(profitManager.claimRewards(alice), 10e18);
    }

    function testDecrementGaugeDebtCeilingUsed() public {
        // grant roles to test contract
        vm.startPrank(governor);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        vm.stopPrank();

        // setup
        // 50 GUILD for alice, 50 GUILD for bob
        guild.mint(alice, 150e18);
        guild.mint(bob, 400e18);
        // add gauges
        guild.setMaxGauges(3);
        guild.addGauge(1, gauge1);
        guild.addGauge(1, gauge2);
        guild.addGauge(1, address(this));
        // 80 votes on gauge1, 40 votes on gauge2, 40 votes on this
        vm.startPrank(alice);
        guild.incrementGauge(gauge1, 10e18);
        guild.incrementGauge(gauge2, 10e18);
        vm.stopPrank();
        vm.startPrank(bob);
        guild.incrementGauge(gauge1, 10e18);
        guild.incrementGauge(address(this), 10e18);
        vm.stopPrank();

        // simulate alice borrows 100 CREDIT on this (gauge 3)
        credit.mint(alice, 100e18);
        issuance = 100e18;
        assertEq(credit.totalSupply(), 200e18);

        // gauge 3 (this) has 25% of votes, but 50% of credit issuance,
        // so nobody can decrease the votes for this gauge
        vm.expectRevert("GuildToken: debt ceiling used");
        vm.prank(bob);
        guild.decrementGauge(address(this), 10e18);

        // alice now votes for gauge3 (this), so that it is still 50% of credit issuance,
        // but has 67% of votes.
        vm.prank(alice);
        guild.incrementGauge(address(this), 50e18);
        // after alice increment :
        // gauge1: 20 votes
        // gauge2: 10 votes
        // gauge3 (this): 60 votes
        // now bob can decrement his gauge vote.
        vm.prank(bob);
        guild.decrementGauge(address(this), 10e18);
    }

    function testDonateToSurplusBuffer() public {
        // initial state
        assertEq(profitManager.surplusBuffer(), 0);
        credit.mint(address(this), 100e18);
        credit.approve(address(profitManager), 100e18);
        assertEq(credit.balanceOf(address(this)), 200e18);
        assertEq(credit.balanceOf(address(profitManager)), 0);

        // cannot donate more than current balance/approval
        vm.expectRevert("ERC20: insufficient allowance");
        profitManager.donateToSurplusBuffer(999e18);

        // donate to surplus buffer
        profitManager.donateToSurplusBuffer(100e18);

        // checks
        assertEq(profitManager.surplusBuffer(), 100e18);
        assertEq(credit.balanceOf(address(this)), 100e18);
        assertEq(credit.balanceOf(address(profitManager)), 100e18);
    }

    function testWithdrawFromSurplusBuffer() public {
        // initial state
        credit.mint(address(this), 100e18);
        credit.approve(address(profitManager), 100e18);
        profitManager.donateToSurplusBuffer(100e18);
        assertEq(profitManager.surplusBuffer(), 100e18);
        assertEq(credit.balanceOf(address(this)), 100e18);
        assertEq(credit.balanceOf(address(profitManager)), 100e18);

        // without role, cannot withdraw
        vm.expectRevert("UNAUTHORIZED");
        profitManager.withdrawFromSurplusBuffer(10e18);

        // grant role to test contract
        vm.prank(governor);
        core.grantRole(CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW, address(this));

        // withdraw
        profitManager.withdrawFromSurplusBuffer(10e18);
        assertEq(profitManager.surplusBuffer(), 90e18);
        assertEq(credit.balanceOf(address(this)), 110e18);
        assertEq(credit.balanceOf(address(profitManager)), 90e18);

        // cannot withdraw more than current buffer
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11)); // underflow
        profitManager.withdrawFromSurplusBuffer(999e18);
    }

    function testDepleteSurplusBuffer() public {
        // grant roles to test contract
        vm.startPrank(governor);
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(this));
        core.grantRole(CoreRoles.GUILD_SURPLUS_BUFFER_WITHDRAW, address(this));
        vm.stopPrank();

        // initial state
        // 100 CREDIT circulating (assuming backed by >= 100 USD)
        assertEq(profitManager.creditMultiplier(), 1e18);
        assertEq(credit.totalSupply(), 100e18);

        // donate 100 to surplus buffer
        credit.mint(address(this), 100e18);
        credit.approve(address(profitManager), 100e18);
        profitManager.donateToSurplusBuffer(100e18);
        assertEq(profitManager.surplusBuffer(), 100e18);
        assertEq(credit.balanceOf(address(profitManager)), 100e18);
        assertEq(credit.totalSupply(), 200e18);

        // apply a loss (1)
        // 30 CREDIT of loans completely default (~30 USD loss)
        // partially deplete surplus buffer
        profitManager.notifyPnL(address(this), -30e18);
        assertEq(profitManager.creditMultiplier(), 1e18); // 0% discounted
        assertEq(profitManager.surplusBuffer(), 70e18);
        assertEq(credit.balanceOf(address(profitManager)), 70e18);

        // apply a gain on an existing loan
        vm.prank(governor);
        profitManager.setProfitSharingConfig(
            1e18, // surplusBufferSplit
            0, // creditSplit
            0, // guildSplit
            0, // otherSplit
            address(0) // otherRecipient
        );
        credit.mint(address(profitManager), 10e18);
        profitManager.notifyPnL(address(this), 10e18);
        assertEq(profitManager.surplusBuffer(), 80e18);
        assertEq(credit.balanceOf(address(profitManager)), 80e18);

        // apply a loss (2)
        // 110 CREDIT of loans completely default (~14 USD loss because CREDIT now worth 0.7 USD)
        // overdraft on surplus buffer, adjust down creditMultiplier
        profitManager.notifyPnL(address(this), -110e18);
        assertEq(profitManager.creditMultiplier(), 0.7e18); // 30% discounted (30 credit net loss)
        assertEq(profitManager.surplusBuffer(), 0);
        assertEq(credit.balanceOf(address(profitManager)), 0);
    }
}
