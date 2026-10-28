//
//  RenewalTracker.swift
//  geekIpa
//
//  续签跟踪：记录每个已签 App 的签名日期与签名方式（免费 Apple ID / 证书）。
//  纯 UserDefaults + JSON 持久化，不改 Core Data 模型；
//  证书类 App 的到期日直接读 CertificatePair.expiration（只读，不写入模型）。
//

import Foundation
import CoreData

// MARK: - 类型

/// 签名方式
enum SignedAppKind: String, Codable {
	/// 免费 Apple ID 签名（描述文件固定 7 天有效，自签名时刻起算）
	case appleID
	/// 证书签名（企业 / UDID 证书，到期日看 CertificatePair.expiration）
	case cert
}

/// 一条签名记录
struct SignedAppRecord: Codable, Equatable {
	var uuid: String
	var name: String
	var kind: SignedAppKind
	/// 签名完成时刻（7 天周期自该时刻起算，即 startOfWeek == signDate）
	var signDate: Date
}

// MARK: - RenewalTracker

final class RenewalTracker {
	static let shared = RenewalTracker()

	/// 免费 Apple ID 签名的固定有效周期（秒）
	static let appleIDValidityInterval: TimeInterval = 7 * 86400

	private let _defaultsKey = "geekipa.renewal.records.v1"
	private let _queue = DispatchQueue(label: "geekipa.renewal.tracker", qos: .utility)

	private init() {}

	// MARK: 写入

	/// 签名完成记录点。
	///
	/// WIRE: SigningHandler 完成处调用 —— 在 SigningHandler.addToDatabase() 的
	/// Storage.shared.addSigned(...) 成功回调里补一行：
	///     RenewalTracker.recordSignedApp(uuid: _uuid, name: bundle?.name ?? "", kind: .cert)
	/// Apple ID 签名管线（AppleID 模块）完成后同样调用，kind 传 .appleID。
	static func recordSignedApp(uuid: String, name: String, kind: SignedAppKind) {
		shared.record(uuid: uuid, name: name, kind: kind, signDate: Date())
	}

	func record(uuid: String, name: String, kind: SignedAppKind, signDate: Date) {
		_queue.sync {
			var all = _loadLocked()
			all[uuid] = SignedAppRecord(uuid: uuid, name: name, kind: kind, signDate: signDate)
			_saveLocked(all)
		}
	}

	func remove(uuid: String) {
		_queue.sync {
			var all = _loadLocked()
			all.removeValue(forKey: uuid)
			_saveLocked(all)
		}
	}


	// MARK: 查询

	func record(for uuid: String) -> SignedAppRecord? {
		_queue.sync { _loadLocked()[uuid] }
	}

	func allRecords() -> [SignedAppRecord] {
		_queue.sync { _loadLocked().values.sorted { $0.signDate > $1.signDate } }
	}

	/// 签名方式；无记录时返回 nil（调用方按证书签名兜底处理）
	func kind(for uuid: String) -> SignedAppKind? {
		record(for: uuid)?.kind
	}

	/// 到期日期。appleID 类 = signDate + 7 天；cert 类 = CertificatePair.expiration。
	func expiryDate(uuid: String) -> Date? {
		if let record = record(for: uuid), record.kind == .appleID {
			return record.signDate.addingTimeInterval(Self.appleIDValidityInterval)
		}
		// cert 类（含无记录的历史 App）：从 Signed 实体的证书关系读到期日
		return _signedApp(uuid: uuid)?.certificate?.expiration
	}

	/// 剩余天数（向下取整，与 Date.expirationInfo() 口径一致；0 表示今天到期）。
	/// 无法确定（无记录且无证书）时返回 nil，调用方不显示徽章。
	func daysRemaining(uuid: String, from now: Date = Date()) -> Int? {
		guard let expiry = expiryDate(uuid: uuid) else { return nil }
		return max(0, Int(expiry.timeIntervalSince(now) / 86400))
	}

	// MARK: - Core Data 只读查询

	private func _signedApp(uuid: String) -> Signed? {
		let context = Storage.shared.context
		var result: Signed?
		context.performAndWait {
			let request: NSFetchRequest<Signed> = Signed.fetchRequest()
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			request.fetchLimit = 1
			result = try? context.fetch(request).first
		}
		return result
	}

	// MARK: - 持久化

	private func _loadLocked() -> [String: SignedAppRecord] {
		guard
			let data = UserDefaults.standard.data(forKey: _defaultsKey),
			let decoded = try? JSONDecoder().decode([String: SignedAppRecord].self, from: data)
		else {
			return [:]
		}
		return decoded
	}

	private func _saveLocked(_ records: [String: SignedAppRecord]) {
		if let data = try? JSONEncoder().encode(records) {
			UserDefaults.standard.set(data, forKey: _defaultsKey)
		}
	}
}
