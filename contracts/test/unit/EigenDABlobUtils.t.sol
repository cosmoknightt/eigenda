// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "../../lib/eigenlayer-middleware/test/utils/BLSMockAVSDeployer.sol";
import {EigenDAHasher} from "../../src/libraries/EigenDAHasher.sol";
import {EigenDAServiceManager, IRewardsCoordinator} from "../../src/core/EigenDAServiceManager.sol";
import {EigenDABlobVerifier} from "../../src/core/EigenDABlobVerifier.sol";
import {EigenDAHasher} from "../../src/libraries/EigenDAHasher.sol";
import {EigenDAServiceManager} from "../../src/core/EigenDAServiceManager.sol";
import {IEigenDAServiceManager} from "../../src/interfaces/IEigenDAServiceManager.sol";

import "forge-std/StdStorage.sol";

contract EigenDABlobUtilsUnit is BLSMockAVSDeployer {
    using stdStorage for StdStorage;

    using BN254 for BN254.G1Point;
    using EigenDAHasher for IEigenDAServiceManager.BatchHeader;
    using EigenDAHasher for IEigenDAServiceManager.ReducedBatchHeader;
    using EigenDAHasher for IEigenDAServiceManager.BlobHeader;
    using EigenDAHasher for IEigenDAServiceManager.BatchMetadata;

    address confirmer = address(uint160(uint256(keccak256(abi.encodePacked("confirmer")))));
    address notConfirmer = address(uint160(uint256(keccak256(abi.encodePacked("notConfirmer")))));
    address rewardsInitiator = address(uint160(uint256(keccak256(abi.encodePacked("rewardsInitiator")))));

    EigenDAServiceManager eigenDAServiceManager;
    EigenDAServiceManager eigenDAServiceManagerImplementation;

    uint8 defaultCodingRatioPercentage = 10;
    uint32 defaultReferenceBlockNumber = 100;
    uint32 defaultConfirmationBlockNumber = 1000;
    uint32 defaultBatchId = 0;

    mapping(uint8 => bool) public quorumNumbersUsed;

    function setUp() virtual public {
        _setUpBLSMockAVSDeployer();

        eigenDAServiceManagerImplementation = new EigenDAServiceManager(
            avsDirectory,
            rewardsCoordinator,
            registryCoordinator,
            stakeRegistry
        );

        address[] memory confirmers = new address[](1);
        confirmers[0] = confirmer;

        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        eigenDAServiceManager = EigenDAServiceManager(
            address(
                new TransparentUpgradeableProxy(
                    address(eigenDAServiceManagerImplementation),
                    address(proxyAdmin),
                    abi.encodeWithSelector(
                        EigenDAServiceManager.initialize.selector,
                        pauserRegistry,
                        0,
                        registryCoordinatorOwner,
                        confirmers,
                        rewardsInitiator
                    )
                )
            )
        );
    }

    function testVerifyBlob_TwoQuorums(uint256 pseudoRandomNumber) public {
        uint256 numQuorumBlobParams = 2;
        IEigenDAServiceManager.BlobHeader[] memory blobHeader = new IEigenDAServiceManager.BlobHeader[](2);
        blobHeader[0] = _generateRandomBlobHeader(pseudoRandomNumber, numQuorumBlobParams);
        uint256 anotherPseudoRandomNumber = uint256(keccak256(abi.encodePacked(pseudoRandomNumber)));
        blobHeader[1] = _generateRandomBlobHeader(anotherPseudoRandomNumber, numQuorumBlobParams);

        IEigenDAServiceManager.BatchHeader memory batchHeader;
        bytes memory firstBlobHash = abi.encodePacked(blobHeader[0].hashBlobHeader());
        bytes memory secondBlobHash = abi.encodePacked(blobHeader[1].hashBlobHeader());
        batchHeader.blobHeadersRoot = keccak256(abi.encodePacked(keccak256(firstBlobHash), keccak256(secondBlobHash)));
        // add dummy quorum numbers and quorum threshold percentages making sure confirmationThresholdPercentage = adversaryThresholdPercentage + defaultCodingRatioPercentage
        for (uint i = 0; i < blobHeader[1].quorumBlobParams.length; i++) {
            batchHeader.quorumNumbers = abi.encodePacked(batchHeader.quorumNumbers, blobHeader[1].quorumBlobParams[i].quorumNumber);
            batchHeader.signedStakeForQuorums = abi.encodePacked(batchHeader.signedStakeForQuorums, blobHeader[1].quorumBlobParams[i].adversaryThresholdPercentage + defaultCodingRatioPercentage);
        }
        batchHeader.referenceBlockNumber = uint32(block.number);

        // add dummy batch metadata
        IEigenDAServiceManager.BatchMetadata memory batchMetadata;
        batchMetadata.batchHeader = batchHeader;
        batchMetadata.signatoryRecordHash = keccak256(abi.encodePacked("signatoryRecordHash"));
        batchMetadata.confirmationBlockNumber = defaultConfirmationBlockNumber;

        stdstore
            .target(address(eigenDAServiceManager))
            .sig("batchIdToBatchMetadataHash(uint32)")
            .with_key(defaultBatchId)
            .checked_write(batchMetadata.hashBatchMetadata());

        EigenDABlobVerifier.BlobVerificationProof memory blobVerificationProof;
        blobVerificationProof.batchId = defaultBatchId;
        blobVerificationProof.batchMetadata = batchMetadata;
        blobVerificationProof.inclusionProof = abi.encodePacked(keccak256(firstBlobHash));
        blobVerificationProof.blobIndex = 1;
        blobVerificationProof.quorumIndices = new bytes(batchHeader.quorumNumbers.length);
        for (uint i = 0; i < batchHeader.quorumNumbers.length; i++) {
            blobVerificationProof.quorumIndices[i] = bytes1(uint8(i));
        }

        uint256 gasBefore = gasleft();
        eigenDAServiceManager.verifyBlob(blobHeader[1], blobVerificationProof);
        uint256 gasAfter = gasleft();
        emit log_named_uint("gas used", gasBefore - gasAfter);
    }

    function testVerifyBlob_InvalidMetadataHash(uint256 pseudoRandomNumber) public {
        uint256 numQuorumBlobParams = pseudoRandomNumber % 192;
        IEigenDAServiceManager.BlobHeader[] memory blobHeader = new IEigenDAServiceManager.BlobHeader[](2);
        blobHeader[0] = _generateRandomBlobHeader(pseudoRandomNumber, numQuorumBlobParams);
        uint256 anotherPseudoRandomNumber = uint256(keccak256(abi.encodePacked(pseudoRandomNumber)));
        blobHeader[1] = _generateRandomBlobHeader(anotherPseudoRandomNumber, numQuorumBlobParams);

        EigenDABlobVerifier.BlobVerificationProof memory blobVerificationProof;
        blobVerificationProof.batchId = defaultBatchId;

        cheats.expectRevert("EigenDABlobVerifier._verifyBlobForQuorums: batchMetadata does not match stored metadata");
        eigenDAServiceManager.verifyBlob(blobHeader[1], blobVerificationProof);
    }

    function testVerifyBlob_InvalidMerkleProof(uint256 pseudoRandomNumber) public {
        uint256 numQuorumBlobParams = pseudoRandomNumber % 192;
        IEigenDAServiceManager.BlobHeader[] memory blobHeader = new IEigenDAServiceManager.BlobHeader[](2);
        blobHeader[0] = _generateRandomBlobHeader(pseudoRandomNumber, numQuorumBlobParams);
        uint256 anotherPseudoRandomNumber = uint256(keccak256(abi.encodePacked(pseudoRandomNumber)));
        blobHeader[1] = _generateRandomBlobHeader(anotherPseudoRandomNumber, numQuorumBlobParams);

        // add dummy batch metadata
        IEigenDAServiceManager.BatchMetadata memory batchMetadata;

        stdstore
            .target(address(eigenDAServiceManager))
            .sig("batchIdToBatchMetadataHash(uint32)")
            .with_key(defaultBatchId)
            .checked_write(batchMetadata.hashBatchMetadata());

        EigenDABlobVerifier.BlobVerificationProof memory blobVerificationProof;
        blobVerificationProof.batchId = defaultBatchId;
        blobVerificationProof.batchMetadata = batchMetadata;
        blobVerificationProof.inclusionProof = abi.encodePacked(bytes32(0));        
        blobVerificationProof.blobIndex = 1;

        cheats.expectRevert("EigenDABlobVerifier._verifyBlobForQuorums: inclusion proof is invalid");
        eigenDAServiceManager.verifyBlob(blobHeader[1], blobVerificationProof);
    }

    function testVerifyBlob_RandomNumberOfQuorums(uint256 pseudoRandomNumber) public {
        uint256 numQuorumBlobParams = 2 + (pseudoRandomNumber % 192);
        IEigenDAServiceManager.BlobHeader[] memory blobHeader = new IEigenDAServiceManager.BlobHeader[](2);
        blobHeader[0] = _generateRandomBlobHeader(pseudoRandomNumber, numQuorumBlobParams);
        uint256 anotherPseudoRandomNumber = uint256(keccak256(abi.encodePacked(pseudoRandomNumber)));
        blobHeader[1] = _generateRandomBlobHeader(anotherPseudoRandomNumber, numQuorumBlobParams);

        IEigenDAServiceManager.BatchHeader memory batchHeader;
        bytes memory firstBlobHash = abi.encodePacked(blobHeader[0].hashBlobHeader());
        bytes memory secondBlobHash = abi.encodePacked(blobHeader[1].hashBlobHeader());
        batchHeader.blobHeadersRoot = keccak256(abi.encodePacked(keccak256(firstBlobHash), keccak256(secondBlobHash)));
        // add dummy quorum numbers and quorum threshold percentages making sure confirmationThresholdPercentage = adversaryThresholdPercentage + defaultCodingRatioPercentage
        for (uint i = 0; i < blobHeader[1].quorumBlobParams.length; i++) {
            batchHeader.quorumNumbers = abi.encodePacked(batchHeader.quorumNumbers, blobHeader[1].quorumBlobParams[i].quorumNumber);
            batchHeader.signedStakeForQuorums = abi.encodePacked(batchHeader.signedStakeForQuorums, blobHeader[1].quorumBlobParams[i].adversaryThresholdPercentage + defaultCodingRatioPercentage);
        }
        batchHeader.referenceBlockNumber = uint32(block.number);

        // add dummy batch metadata
        IEigenDAServiceManager.BatchMetadata memory batchMetadata;
        batchMetadata.batchHeader = batchHeader;
        batchMetadata.signatoryRecordHash = keccak256(abi.encodePacked("signatoryRecordHash"));
        batchMetadata.confirmationBlockNumber = defaultConfirmationBlockNumber;

        stdstore
            .target(address(eigenDAServiceManager))
            .sig("batchIdToBatchMetadataHash(uint32)")
            .with_key(defaultBatchId)
            .checked_write(batchMetadata.hashBatchMetadata());

        EigenDABlobVerifier.BlobVerificationProof memory blobVerificationProof;
        blobVerificationProof.batchId = defaultBatchId;
        blobVerificationProof.batchMetadata = batchMetadata;
        blobVerificationProof.inclusionProof = abi.encodePacked(keccak256(firstBlobHash));
        blobVerificationProof.blobIndex = 1;
        blobVerificationProof.quorumIndices = new bytes(batchHeader.quorumNumbers.length);
        for (uint i = 0; i < batchHeader.quorumNumbers.length; i++) {
            blobVerificationProof.quorumIndices[i] = bytes1(uint8(i));
        }

        uint256 gasBefore = gasleft();
        eigenDAServiceManager.verifyBlob(blobHeader[1], blobVerificationProof);
        uint256 gasAfter = gasleft();
        emit log_named_uint("gas used", gasBefore - gasAfter);
    }

    function xtestVerifyBlob_RequiredQuorumsNotMet(uint256 pseudoRandomNumber) public {
        uint256 numQuorumBlobParams = 1;
        IEigenDAServiceManager.BlobHeader[] memory blobHeader = new IEigenDAServiceManager.BlobHeader[](2);
        blobHeader[0] = _generateRandomBlobHeader(pseudoRandomNumber, numQuorumBlobParams);
        uint256 anotherPseudoRandomNumber = uint256(keccak256(abi.encodePacked(pseudoRandomNumber)));
        blobHeader[1] = _generateRandomBlobHeader(anotherPseudoRandomNumber, numQuorumBlobParams);

        IEigenDAServiceManager.BatchHeader memory batchHeader;
        bytes memory firstBlobHash = abi.encodePacked(blobHeader[0].hashBlobHeader());
        bytes memory secondBlobHash = abi.encodePacked(blobHeader[1].hashBlobHeader());
        batchHeader.blobHeadersRoot = keccak256(abi.encodePacked(keccak256(firstBlobHash), keccak256(secondBlobHash)));
        // add dummy quorum numbers and quorum threshold percentages making sure confirmationThresholdPercentage = adversaryThresholdPercentage + defaultCodingRatioPercentage
        for (uint i = 0; i < blobHeader[1].quorumBlobParams.length; i++) {
            batchHeader.quorumNumbers = abi.encodePacked(batchHeader.quorumNumbers, blobHeader[1].quorumBlobParams[i].quorumNumber);
            batchHeader.signedStakeForQuorums = abi.encodePacked(batchHeader.signedStakeForQuorums, blobHeader[1].quorumBlobParams[i].adversaryThresholdPercentage + defaultCodingRatioPercentage);
        }
        batchHeader.referenceBlockNumber = uint32(block.number);

        // add dummy batch metadata
        IEigenDAServiceManager.BatchMetadata memory batchMetadata;
        batchMetadata.batchHeader = batchHeader;
        batchMetadata.signatoryRecordHash = keccak256(abi.encodePacked("signatoryRecordHash"));
        batchMetadata.confirmationBlockNumber = defaultConfirmationBlockNumber;

        stdstore
            .target(address(eigenDAServiceManager))
            .sig("batchIdToBatchMetadataHash(uint32)")
            .with_key(defaultBatchId)
            .checked_write(batchMetadata.hashBatchMetadata());

        EigenDABlobVerifier.BlobVerificationProof memory blobVerificationProof;
        blobVerificationProof.batchId = defaultBatchId;
        blobVerificationProof.batchMetadata = batchMetadata;
        blobVerificationProof.inclusionProof = abi.encodePacked(keccak256(firstBlobHash));
        blobVerificationProof.blobIndex = 1;
        blobVerificationProof.quorumIndices = new bytes(batchHeader.quorumNumbers.length);
        for (uint i = 0; i < batchHeader.quorumNumbers.length; i++) {
            blobVerificationProof.quorumIndices[i] = bytes1(uint8(i));
        }

        cheats.expectRevert("EigenDABlobVerifier._verifyBlobForQuorums: required quorums are not a subset of the confirmed quorums");
        eigenDAServiceManager.verifyBlob(blobHeader[1], blobVerificationProof);
    }

    function xtestVerifyBlob_AdversayThresholdNotMet(uint256 pseudoRandomNumber) public {
        uint256 numQuorumBlobParams = 2;
        IEigenDAServiceManager.BlobHeader[] memory blobHeader = new IEigenDAServiceManager.BlobHeader[](2);
        blobHeader[0] = _generateRandomBlobHeader(pseudoRandomNumber, numQuorumBlobParams);
        uint256 anotherPseudoRandomNumber = uint256(keccak256(abi.encodePacked(pseudoRandomNumber)));
        blobHeader[1] = _generateRandomBlobHeader(anotherPseudoRandomNumber, numQuorumBlobParams);

        for (uint i = 0; i < numQuorumBlobParams; i++) {
            blobHeader[0].quorumBlobParams[i].adversaryThresholdPercentage = eigenDAServiceManager.getQuorumAdversaryThresholdPercentage(blobHeader[0].quorumBlobParams[i].quorumNumber) - 1;
            blobHeader[1].quorumBlobParams[i].adversaryThresholdPercentage = eigenDAServiceManager.getQuorumAdversaryThresholdPercentage(blobHeader[1].quorumBlobParams[i].quorumNumber) - 1;
        }

        IEigenDAServiceManager.BatchHeader memory batchHeader;
        bytes memory firstBlobHash = abi.encodePacked(blobHeader[0].hashBlobHeader());
        bytes memory secondBlobHash = abi.encodePacked(blobHeader[1].hashBlobHeader());
        batchHeader.blobHeadersRoot = keccak256(abi.encodePacked(keccak256(firstBlobHash), keccak256(secondBlobHash)));
        // add dummy quorum numbers and quorum threshold percentages making sure confirmationThresholdPercentage = adversaryThresholdPercentage + defaultCodingRatioPercentage
        for (uint i = 0; i < blobHeader[1].quorumBlobParams.length; i++) {
            batchHeader.quorumNumbers = abi.encodePacked(batchHeader.quorumNumbers, blobHeader[1].quorumBlobParams[i].quorumNumber);
            batchHeader.signedStakeForQuorums = abi.encodePacked(batchHeader.signedStakeForQuorums, blobHeader[1].quorumBlobParams[i].adversaryThresholdPercentage + defaultCodingRatioPercentage);
        }
        batchHeader.referenceBlockNumber = uint32(block.number);

        // add dummy batch metadata
        IEigenDAServiceManager.BatchMetadata memory batchMetadata;
        batchMetadata.batchHeader = batchHeader;
        batchMetadata.signatoryRecordHash = keccak256(abi.encodePacked("signatoryRecordHash"));
        batchMetadata.confirmationBlockNumber = defaultConfirmationBlockNumber;

        stdstore
            .target(address(eigenDAServiceManager))
            .sig("batchIdToBatchMetadataHash(uint32)")
            .with_key(defaultBatchId)
            .checked_write(batchMetadata.hashBatchMetadata());

        EigenDABlobVerifier.BlobVerificationProof memory blobVerificationProof;
        blobVerificationProof.batchId = defaultBatchId;
        blobVerificationProof.batchMetadata = batchMetadata;
        blobVerificationProof.inclusionProof = abi.encodePacked(keccak256(firstBlobHash));
        blobVerificationProof.blobIndex = 1;
        blobVerificationProof.quorumIndices = new bytes(batchHeader.quorumNumbers.length);
        for (uint i = 0; i < batchHeader.quorumNumbers.length; i++) {
            blobVerificationProof.quorumIndices[i] = bytes1(uint8(i));
        }

        cheats.expectRevert("EigenDABlobVerifier._verifyBlobForQuorums: adversaryThresholdPercentage is not met");
        eigenDAServiceManager.verifyBlob(blobHeader[1], blobVerificationProof);
    }

    function testVerifyBlob_QuorumNumberMismatch(uint256 pseudoRandomNumber) public {
        uint256 numQuorumBlobParams = 2;
        IEigenDAServiceManager.BlobHeader[] memory blobHeader = new IEigenDAServiceManager.BlobHeader[](2);
        blobHeader[0] = _generateRandomBlobHeader(pseudoRandomNumber, numQuorumBlobParams);
        uint256 anotherPseudoRandomNumber = uint256(keccak256(abi.encodePacked(pseudoRandomNumber)));
        blobHeader[1] = _generateRandomBlobHeader(anotherPseudoRandomNumber, numQuorumBlobParams);

        IEigenDAServiceManager.BatchHeader memory batchHeader;
        bytes memory firstBlobHash = abi.encodePacked(blobHeader[0].hashBlobHeader());
        bytes memory secondBlobHash = abi.encodePacked(blobHeader[1].hashBlobHeader());
        batchHeader.blobHeadersRoot = keccak256(abi.encodePacked(keccak256(firstBlobHash), keccak256(secondBlobHash)));
        // add dummy quorum numbers and quorum threshold percentages making sure confirmationThresholdPercentage = adversaryThresholdPercentage + defaultCodingRatioPercentage
        for (uint i = 0; i < blobHeader[1].quorumBlobParams.length; i++) {
            batchHeader.quorumNumbers = abi.encodePacked(batchHeader.quorumNumbers, blobHeader[1].quorumBlobParams[i].quorumNumber);
            batchHeader.signedStakeForQuorums = abi.encodePacked(batchHeader.signedStakeForQuorums, blobHeader[1].quorumBlobParams[i].adversaryThresholdPercentage + defaultCodingRatioPercentage);
        }
        batchHeader.referenceBlockNumber = uint32(block.number);

        // add dummy batch metadata
        IEigenDAServiceManager.BatchMetadata memory batchMetadata;
        batchMetadata.batchHeader = batchHeader;
        batchMetadata.signatoryRecordHash = keccak256(abi.encodePacked("signatoryRecordHash"));
        batchMetadata.confirmationBlockNumber = defaultConfirmationBlockNumber;

        stdstore
            .target(address(eigenDAServiceManager))
            .sig("batchIdToBatchMetadataHash(uint32)")
            .with_key(defaultBatchId)
            .checked_write(batchMetadata.hashBatchMetadata());

        EigenDABlobVerifier.BlobVerificationProof memory blobVerificationProof;
        blobVerificationProof.batchId = defaultBatchId;
        blobVerificationProof.batchMetadata = batchMetadata;
        blobVerificationProof.inclusionProof = abi.encodePacked(keccak256(firstBlobHash));
        blobVerificationProof.blobIndex = 1;
        blobVerificationProof.quorumIndices = new bytes(batchHeader.quorumNumbers.length);
        for (uint i = 0; i < batchHeader.quorumNumbers.length; i++) {
            // implant the incorrect quorumNumbers here
            blobVerificationProof.quorumIndices[i] = bytes1(uint8(batchHeader.quorumNumbers.length - 1 - i));
        }

        cheats.expectRevert("EigenDABlobVerifier._verifyBlobForQuorums: quorumNumber does not match");
        eigenDAServiceManager.verifyBlob(blobHeader[1], blobVerificationProof);
    }

    function testVerifyBlob_QuorumThresholdNotMet(uint256 pseudoRandomNumber) public {
        uint256 numQuorumBlobParams = 2;
        IEigenDAServiceManager.BlobHeader[] memory blobHeader = new IEigenDAServiceManager.BlobHeader[](2);
        blobHeader[0] = _generateRandomBlobHeader(pseudoRandomNumber, numQuorumBlobParams);
        uint256 anotherPseudoRandomNumber = uint256(keccak256(abi.encodePacked(pseudoRandomNumber)));
        blobHeader[1] = _generateRandomBlobHeader(anotherPseudoRandomNumber, numQuorumBlobParams);

        IEigenDAServiceManager.BatchHeader memory batchHeader;
        bytes memory firstBlobHash = abi.encodePacked(blobHeader[0].hashBlobHeader());
        bytes memory secondBlobHash = abi.encodePacked(blobHeader[1].hashBlobHeader());
        batchHeader.blobHeadersRoot = keccak256(abi.encodePacked(keccak256(firstBlobHash), keccak256(secondBlobHash)));
        // add dummy quorum numbers and quorum threshold percentages making sure confirmationThresholdPercentage = 100
        for (uint i = 0; i < blobHeader[1].quorumBlobParams.length; i++) {
            batchHeader.quorumNumbers = abi.encodePacked(batchHeader.quorumNumbers, blobHeader[1].quorumBlobParams[i].quorumNumber);
            batchHeader.signedStakeForQuorums = abi.encodePacked(batchHeader.signedStakeForQuorums, blobHeader[1].quorumBlobParams[i].confirmationThresholdPercentage - 1);
        }
        batchHeader.referenceBlockNumber = uint32(block.number);

        // add dummy batch metadata
        IEigenDAServiceManager.BatchMetadata memory batchMetadata;
        batchMetadata.batchHeader = batchHeader;
        batchMetadata.signatoryRecordHash = keccak256(abi.encodePacked("signatoryRecordHash"));
        batchMetadata.confirmationBlockNumber = defaultConfirmationBlockNumber;

        stdstore
            .target(address(eigenDAServiceManager))
            .sig("batchIdToBatchMetadataHash(uint32)")
            .with_key(defaultBatchId)
            .checked_write(batchMetadata.hashBatchMetadata());

        EigenDABlobVerifier.BlobVerificationProof memory blobVerificationProof;
        blobVerificationProof.batchId = defaultBatchId;
        blobVerificationProof.batchMetadata = batchMetadata;
        blobVerificationProof.inclusionProof = abi.encodePacked(keccak256(firstBlobHash));
        blobVerificationProof.blobIndex = 1;
        blobVerificationProof.quorumIndices = new bytes(batchHeader.quorumNumbers.length);
        for (uint i = 0; i < batchHeader.quorumNumbers.length; i++) {
            // implant the incorrect quorumNumbers here
            blobVerificationProof.quorumIndices[i] = bytes1(uint8(i));
        }

        cheats.expectRevert("EigenDABlobVerifier._verifyBlobForQuorums: confirmationThresholdPercentage is not met");
        eigenDAServiceManager.verifyBlob(blobHeader[1], blobVerificationProof);
    }

    // generates a random blob header with the given coding ratio percentage as the ratio of original data to encoded data
    function _generateRandomBlobHeader(uint256 pseudoRandomNumber, uint256 numQuorumsBlobParams) internal returns (IEigenDAServiceManager.BlobHeader memory) {
        if(pseudoRandomNumber == 0) {
            pseudoRandomNumber = 1;
        }

        IEigenDAServiceManager.BlobHeader memory blobHeader;
        blobHeader.commitment.X = uint256(keccak256(abi.encodePacked(pseudoRandomNumber, "blobHeader.commitment.X"))) % BN254.FP_MODULUS;
        blobHeader.commitment.Y = uint256(keccak256(abi.encodePacked(pseudoRandomNumber, "blobHeader.commitment.Y"))) % BN254.FP_MODULUS;

        blobHeader.dataLength = uint32(uint256(keccak256(abi.encodePacked(pseudoRandomNumber, "blobHeader.dataLength"))));

        blobHeader.quorumBlobParams = new IEigenDAServiceManager.QuorumBlobParam[](numQuorumsBlobParams);
        blobHeader.dataLength = uint32(uint256(keccak256(abi.encodePacked(pseudoRandomNumber, "blobHeader.dataLength"))));
        for (uint i = 0; i < numQuorumsBlobParams; i++) {
            if(i < 2){
                blobHeader.quorumBlobParams[i].quorumNumber = uint8(i);
            } else {
                blobHeader.quorumBlobParams[i].quorumNumber = uint8(uint256(keccak256(abi.encodePacked(pseudoRandomNumber, "blobHeader.quorumBlobParams[i].quorumNumber", i)))) % 192;

                // make sure it isn't already used
                while(quorumNumbersUsed[blobHeader.quorumBlobParams[i].quorumNumber]) {
                    blobHeader.quorumBlobParams[i].quorumNumber = uint8(uint256(blobHeader.quorumBlobParams[i].quorumNumber) + 1) % 192;
                }
                quorumNumbersUsed[blobHeader.quorumBlobParams[i].quorumNumber] = true;
            }
            
            blobHeader.quorumBlobParams[i].adversaryThresholdPercentage = eigenDAServiceManager.getQuorumAdversaryThresholdPercentage(blobHeader.quorumBlobParams[i].quorumNumber);
            blobHeader.quorumBlobParams[i].chunkLength = uint32(uint256(keccak256(abi.encodePacked(pseudoRandomNumber, "blobHeader.quorumBlobParams[i].chunkLength", i))));
            blobHeader.quorumBlobParams[i].confirmationThresholdPercentage = blobHeader.quorumBlobParams[i].adversaryThresholdPercentage + 1;
        }
        // mark all quorum numbers as unused
        for (uint i = 0; i < numQuorumsBlobParams; i++) {
            quorumNumbersUsed[blobHeader.quorumBlobParams[i].quorumNumber] = false;
        }

        return blobHeader;
    }

}