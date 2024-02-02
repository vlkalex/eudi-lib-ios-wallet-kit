/*
Copyright (c) 2023 European Commission

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Created on 04/10/2023 
*/

import Foundation
import SwiftCBOR
import MdocDataModel18013
import MdocSecurity18013
import MdocDataTransfer18013
import SiopOpenID4VP
import JOSESwift
import Logging
import UIKit
import SafariServices

/// Implements remote attestation presentation to online verifier

/// Implementation is based on the OpenID4VP – Draft 18 specification
public class OpenId4VpService: PresentationService {
	public var status: TransferStatus = .initialized
	var openid4VPlink: String
	var docs: [DeviceResponse]!
	var iaca: [SecCertificate]!
	var dauthMethod: DeviceAuthMethod
	var devicePrivateKey: CoseKeyPrivate!
	var logger = Logger(label: "OpenId4VpService")
	var presentationDefinition: PresentationDefinition?
	var resolvedRequestData: ResolvedRequestData?
	var siopOpenId4Vp: SiopOpenID4VP!
	var walletConf: WalletOpenId4VPConfiguration!
	public var flow: FlowType

	public init(parameters: [String: Any], qrCode: Data, openId4VpVerifierApiUri: String?) throws {
		self.flow = .openid4vp(qrCode: qrCode)
		guard let cfg = Self.getWalletConf(verifierApiUrl: openId4VpVerifierApiUri ?? "http://localhost:8080") else {
			throw PresentationSession.makeError(str: "INVALID_WALLET_CONFIGURATION")
		}
		walletConf = cfg
		guard let (docs, devicePrivateKey, iaca, dauthMethod) = MdocHelpers.initializeData(parameters: parameters) else {
			throw PresentationSession.makeError(str: "MDOC_DATA_NOT_AVAILABLE")
		}
		self.docs = docs; self.devicePrivateKey = devicePrivateKey; self.iaca = iaca; self.dauthMethod = dauthMethod
		siopOpenId4Vp = SiopOpenID4VP(walletConfiguration: walletConf)
		guard let openid4VPlink = String(data: qrCode, encoding: .utf8) else {
			throw PresentationSession.makeError(str: "QR_DATA_MALFORMED")
		}
		self.openid4VPlink = openid4VPlink
	}
	
	public func startQrEngagement() async throws -> Data? { nil }
	
	///  Receive request from an openid4vp URL
	///
	/// - Returns: The requested items.
	public func receiveRequest() async throws -> [String: Any] {
		guard status != .error, let openid4VPURI = URL(string: openid4VPlink) else { throw PresentationSession.makeError(str: "Invalid link \(openid4VPlink)") }
			switch try await siopOpenId4Vp.authorize(url: openid4VPURI)  {
			case .notSecured(data: _):
				throw PresentationSession.makeError(str: "Not secure request received.")
			case let .jwt(request: resolvedRequestData):
				self.resolvedRequestData = resolvedRequestData
				switch resolvedRequestData {
				case let .vpToken(vp):
					self.presentationDefinition = vp.presentationDefinition
					let items = parsePresentationDefinition(vp.presentationDefinition)
					guard let items else { throw PresentationSession.makeError(str: "Invalid presentation definition") }
					return [UserRequestKeys.valid_items_requested.rawValue: items]
				default: throw PresentationSession.makeError(str: "SiopAuthentication request received, not supported yet.")
				}
			}
	}
	
	/// Send response via openid4vp
	///
	/// - Parameters:
	///   - userAccepted: True if user accepted to send the response
	///   - itemsToSend: The selected items to send organized in document types and namespaces
	public func sendResponse(userAccepted: Bool, itemsToSend: RequestItems) async throws {
		guard let pd = presentationDefinition, let resolved = resolvedRequestData else {
			throw PresentationSession.makeError(str: "Unexpected error")
		}
		guard userAccepted, itemsToSend.count > 0 else {
			try await SendVpToken(nil, pd, resolved)
			return
		}
		logger.info("Openid4vp request items: \(itemsToSend)")
		guard let (deviceResponse, _, _) = try MdocHelpers.getDeviceResponseToSend(deviceRequest: nil, deviceResponses: docs, selectedItems: itemsToSend, dauthMethod: dauthMethod) else { throw PresentationSession.makeError(str: "DOCUMENT_ERROR") }
		// Obtain consent
		let vpTokenStr = Data(deviceResponse.toCBOR(options: CBOROptions()).encode()).base64URLEncodedString()
		try await SendVpToken(vpTokenStr, pd, resolved)
	}
	
	fileprivate func SendVpToken(_ vpTokenStr: String?, _ pd: PresentationDefinition, _ resolved: ResolvedRequestData) async throws {
		let consent: ClientConsent = if let vpTokenStr { .vpToken(vpToken: vpTokenStr, presentationSubmission: .init(id: pd.id, definitionID: pd.id, descriptorMap: [])) } else { .negative(message: "Rejected") }
		// Generate a direct post authorisation response
		let response = try AuthorizationResponse(resolvedRequest: resolved, consent: consent, walletOpenId4VPConfig: walletConf)
		let result: DispatchOutcome = try await siopOpenId4Vp.dispatch(response: response)
		if case let .accepted(url) = result {
			logger.info("Dispatch accepted, return url: \(url?.absoluteString ?? "")")
			if let url {
				await presentSafariView(url)
			}
		} else if case let .rejected(reason) = result {
			logger.info("Dispatch rejected, reason: \(reason)")
			throw PresentationSession.makeError(str: reason)
		}
	}
	
	@MainActor
	func presentSafariView(_ url: URL) {
		let vc = SFSafariViewController(url: url)
		if #available(iOS 15.0, *) {
			guard let w = UIApplication.shared.firstKeyWindow else { return }
			w.rootViewController?.present(vc, animated: true)
		} else {
			guard let w = UIApplication.shared.keyWindow else { return }
			w.rootViewController?.present(vc, animated: true)
		}
	}
	
	/// Parse mDoc request from presentation definition (Presentation Exchange 2.0.0 protocol)
	func parsePresentationDefinition(_ presentationDefinition: PresentationDefinition) -> RequestItems? {
		guard let fieldConstraints = presentationDefinition.inputDescriptors.first?.constraints.fields else { return nil }
		guard let docType = fieldConstraints.first(where: {$0.paths.first == "$.mdoc.doctype" })?.filter?["const"] as? String else { return nil }
		guard let namespace = fieldConstraints.first(where: {$0.paths.first == "$.mdoc.namespace" })?.filter?["const"] as? String else { return nil }
		let requestedFields = fieldConstraints.filter { $0.intentToRetain != nil }.compactMap { $0.paths.first?.replacingOccurrences(of: "$.mdoc.", with: "") }
		return [docType:[namespace:requestedFields]]
	}
	
	static var chainVerifier: CertificateTrust = { certificates in
		let chainVerifier = X509CertificateChainVerifier()
		let verified = try? chainVerifier.verifyCertificateChain(base64Certificates: certificates)
		let result = chainVerifier.isChainTrustResultSuccesful(verified ?? .failure)
		return result
	}
	
	/// OpenId4VP wallet configuration
	static func getWalletConf(verifierApiUrl: String) -> WalletOpenId4VPConfiguration? {
		guard let rsaPrivateKey = try? KeyController.generateRSAPrivateKey(), let privateKey = try? KeyController.generateECDHPrivateKey(),
			  let rsaPublicKey = try? KeyController.generateRSAPublicKey(from: rsaPrivateKey) else { return nil }
		guard let rsaJWK = try? RSAPublicKey(publicKey: rsaPublicKey, additionalParameters: ["use": "sig", "kid": UUID().uuidString, "alg": "RS256"]) else { return nil }
		guard let keySet = try? WebKeySet(jwk: rsaJWK) else { return nil }
		let res = WalletOpenId4VPConfiguration(subjectSyntaxTypesSupported: [.decentralizedIdentifier, .jwkThumbprint], preferredSubjectSyntaxType: .jwkThumbprint, decentralizedIdentifier: try! DecentralizedIdentifier(rawValue: "did:example:123"), signingKey: privateKey, signingKeySet: keySet, supportedClientIdSchemes: [.x509SanDns(trust: chainVerifier)], vpFormatsSupported: [])
		return res
	}

}

extension UIApplication {
	@available(iOS 15.0, *)
	var firstKeyWindow: UIWindow? {
				return UIApplication.shared.connectedScenes
						.compactMap { $0 as? UIWindowScene }
						.filter { $0.activationState == .foregroundActive }
						.first?.keyWindow
		}
}
