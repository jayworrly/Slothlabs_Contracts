const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OFT Bridging", function () {

    const baseEid = 1;
    const avalancheEid = 2;
    const initialSupply = ethers.parseEther("1000000");

    let owner, user;
    let dreamsToken, dreamsProxyOFT, dreamsOFT;
    let endpointBase, endpointAvalanche;

    beforeEach(async function () {
        [owner, user] = await ethers.getSigners();

        // 1. Deploy mock DREAMS token
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        dreamsToken = await MockERC20.deploy("DREAMS", "DRM", 18);
        await dreamsToken.mint(user.address, initialSupply);

        // 2. Deploy mock LayerZero endpoints
        const LZEndpointMock = await ethers.getContractFactory("LZEndpointMock");
        endpointBase = await LZEndpointMock.deploy(baseEid);
        endpointAvalanche = await LZEndpointMock.deploy(avalancheEid);

        // 3. Deploy OFT contracts
        const DreamsProxyOFT = await ethers.getContractFactory("DreamsProxyOFT");
        dreamsProxyOFT = await DreamsProxyOFT.deploy(await endpointBase.getAddress(), await dreamsToken.getAddress());

        const DreamsOFT = await ethers.getContractFactory("DreamsOFT");
        dreamsOFT = await DreamsOFT.deploy("DREAMS (LayerZero)", "DRM", await endpointAvalanche.getAddress(), owner.address);

        // 4. Set peers for endpoints
        await endpointBase.setPeer(avalancheEid, await endpointAvalanche.getAddress());
        await endpointAvalanche.setPeer(baseEid, await endpointBase.getAddress());

        // 5. Set peers for OFT contracts
        await dreamsProxyOFT.setPeer(avalancheEid, ethers.utils.solidityPack(['address'], [await dreamsOFT.getAddress()]));
        await dreamsOFT.setPeer(baseEid, ethers.utils.solidityPack(['address'], [await dreamsProxyOFT.getAddress()]));
    });

    it("should bridge tokens from Base to Avalanche", async function () {
        const bridgeAmount = ethers.parseEther("1000");
        const userAddressBytes = ethers.utils.solidityPack(['address'], [user.address]);

        // Approve the proxy to spend DREAMS tokens
        await dreamsToken.connect(user).approve(await dreamsProxyOFT.getAddress(), bridgeAmount);

        // Define send parameters
        const sendParam = {
            dstEid: avalancheEid,
            to: userAddressBytes,
            amountLD: bridgeAmount,
            minAmountLD: bridgeAmount,
            extraOptions: "0x",
            composeMsg: "0x",
            oftCmd: "0x"
        };
        
        const fee = await dreamsProxyOFT.quote(sendParam, false);

        // Bridge tokens
        await dreamsProxyOFT.connect(user).send(sendParam, fee, user.address, { value: fee.nativeFee });
        
        // Check balances
        expect(await dreamsToken.balanceOf(user.address)).to.equal(initialSupply.sub(bridgeAmount));
        expect(await dreamsToken.balanceOf(await dreamsProxyOFT.getAddress())).to.equal(bridgeAmount);
        expect(await dreamsOFT.balanceOf(user.address)).to.equal(bridgeAmount);
    });

    it("should bridge tokens back from Avalanche to Base", async function () {
        const bridgeAmount = ethers.parseEther("1000");
        const userAddressBytes = ethers.utils.solidityPack(['address'], [user.address]);
        
        // First, bridge from Base to Avalanche to get tokens on Avalanche
        await dreamsToken.connect(user).approve(await dreamsProxyOFT.getAddress(), bridgeAmount);
        let sendParam = {
            dstEid: avalancheEid,
            to: userAddressBytes,
            amountLD: bridgeAmount,
            minAmountLD: bridgeAmount,
            extraOptions: "0x",
            composeMsg: "0x",
            oftCmd: "0x"
        };
        let fee = await dreamsProxyOFT.quote(sendParam, false);
        await dreamsProxyOFT.connect(user).send(sendParam, fee, user.address, { value: fee.nativeFee });

        // Now, bridge back from Avalanche to Base
        const avalancheBalanceBefore = await dreamsOFT.balanceOf(user.address);
        const baseBalanceBefore = await dreamsToken.balanceOf(user.address);

        sendParam = {
            dstEid: baseEid,
            to: userAddressBytes,
            amountLD: bridgeAmount,
            minAmountLD: bridgeAmount,
            extraOptions: "0x",
            composeMsg: "0x",
            oftCmd: "0x"
        };
        fee = await dreamsOFT.quote(sendParam, false);
        await dreamsOFT.connect(user).send(sendParam, fee, user.address, { value: fee.nativeFee });

        // Check balances
        expect(await dreamsOFT.balanceOf(user.address)).to.equal(avalancheBalanceBefore.sub(bridgeAmount));
        expect(await dreamsToken.balanceOf(user.address)).to.equal(baseBalanceBefore.add(bridgeAmount));
        expect(await dreamsToken.balanceOf(await dreamsProxyOFT.getAddress())).to.equal(0);
    });
});
