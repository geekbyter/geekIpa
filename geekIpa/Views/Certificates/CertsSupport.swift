//
//  CertsSupport.swift
//  geekIpa
//
//  证书页支撑代码：证书类型判定、X509 证书解析（Subject/Issuer/序列号/SHA-1）、
//  有效期计算与格式化。全部 iOS 16+ API，解析失败一律返回 nil，由 UI 显示「—」。
//

import Foundation
import SwiftUI
import Security
import CryptoKit

// MARK: - 证书类型（规格书 §3.1）

/// 证书类型判定规则：
/// - nickname 以 "Apple ID（" 开头 → Apple ID 证书（紫）
/// - ppQCheck == true → 企业证书（琥珀）
/// - 其余 → UDID 证书（蓝）
enum GeekCertKind: String, Identifiable {
	case udid
	case appleID
	case enterprise

	var id: String { rawValue }

	init(cert: CertificatePair) {
		if let nickname = cert.nickname, nickname.hasPrefix("Apple ID（") {
			self = .appleID
		} else if cert.ppQCheck {
			self = .enterprise
		} else {
			self = .udid
		}
	}

	var title: String {
		switch self {
		case .udid: return "UDID 证书"
		case .appleID: return "Apple ID 证书"
		case .enterprise: return "企业证书"
		}
	}

	var color: Color {
		switch self {
		case .udid: return .geekPrimary
		case .appleID: return .geekPurple
		case .enterprise: return .geekWarning
		}
	}

	var icon: String {
		switch self {
		case .udid: return "iphone.badge.checkmark"
		case .appleID: return "person.badge.key"
		case .enterprise: return "building.2"
		}
	}
}

// MARK: - 有效期状态（规格书 §3.2 / §5）

enum GeekCertExpiryState {
	case valid(days: Int)
	case expiringSoon(days: Int) // ≤ 30 天
	case expired

	init(expiration: Date?, now: Date = .now) {
		guard let expiration else {
			// 读不到有效期时按有效处理，由 UI 显示「—」
			self = .valid(days: .max)
			return
		}
		let interval = expiration.timeIntervalSince(now)
		if interval <= 0 {
			self = .expired
		} else {
			let days = Int(interval / 86400)
			self = days <= 30 ? .expiringSoon(days: days) : .valid(days: days)
		}
	}

	/// 剩余天数文本（已过期返回 nil）
	var remainingText: String? {
		switch self {
		case .valid(let days):
			return days == .max ? nil : "剩余 \(days) 天"
		case .expiringSoon(let days):
			return "剩余 \(days) 天"
		case .expired:
			return nil
		}
	}

	var color: Color {
		switch self {
		case .valid: return .secondary
		case .expiringSoon: return .geekWarning
		case .expired: return .geekDanger
		}
	}

	var isExpired: Bool {
		if case .expired = self { return true }
		return false
	}
}

// MARK: - X509 证书解析

/// 从描述文件内嵌的 DER 证书（Certificate.DeveloperCertificates）解析 X509 信息。
/// 任何一步失败都保持 nil，UI 层显示「—」。
struct GeekX509Info {
	var subject: String?
	var issuer: String?
	var serialNumber: String?
	var sha1Fingerprint: String?

	init?(derData: Data?) {
		guard
			let derData,
			let certificate = SecCertificateCreateWithData(nil, derData as CFData)
		else { return nil }

		// Subject 摘要（iOS 公开 API）
		subject = SecCertificateCopySubjectSummary(certificate) as String?

		// SHA-1 指纹（CryptoKit）
		sha1Fingerprint = Insecure.SHA1
			.hash(data: derData)
			.map { String(format: "%02X", $0) }
			.joined(separator: ":")

		// 序列号（iOS 11+ 公开 API；拿不到就保持 nil，UI 显示「—」）
		if let serial = SecCertificateCopySerialNumberData(certificate, nil) as Data? {
			serialNumber = serial.map { String(format: "%02X", $0) }.joined(separator: ":")
		}

		// Issuer 在 iOS 无公开解析接口，保持 nil（UI 显示「—」）
		issuer = nil
	}
}

// MARK: - 日期格式化

enum GeekDateFormat {
	static let day: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "zh_CN")
		formatter.dateFormat = "yyyy年M月d日"
		return formatter
	}()

	static let dayTime: DateFormatter = {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "zh_CN")
		formatter.dateFormat = "yyyy年M月d日 HH:mm"
		return formatter
	}()

	static func dayString(_ date: Date?) -> String {
		guard let date else { return "—" }
		return day.string(from: date)
	}

	static func dayTimeString(_ date: Date?) -> String {
		guard let date else { return "—" }
		return dayTime.string(from: date)
	}
}

// MARK: - 本机 UDID（手动录入）

enum GeekDeviceIdentity {
	/// 已录入的 UDID（无则为 nil）
	static var udid: String? { DeviceIdentity.udid }
}
