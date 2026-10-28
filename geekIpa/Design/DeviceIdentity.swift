//
//  DeviceIdentity.swift
//  geekIpa
//
//  设备 UDID 的本地存储与校验。
//  设计取舍：不再采用「配对文件」这类需要外部文件的概念；UDID 由用户从电脑端（爱思/Finder/iTunes）
//  或既有签名工具中复制后手动录入，仅保存在本机 UserDefaults，仅用于向 Apple 注册设备。
//

import Foundation

enum DeviceIdentity {

	private static let _key = "geekipa.device.udid"

	/// 已录入的 UDID（未录入或格式非法时为 nil）
	static var udid: String? {
		guard let raw = UserDefaults.standard.string(forKey: _key) else { return nil }
		return normalized(raw)
	}

	/// 是否已录入可用 UDID
	static var hasUDID: Bool { udid != nil }

	/// 保存 / 清除
	static func save(_ raw: String) -> Bool {
		guard let normalizedValue = normalized(raw) else { return false }
		UserDefaults.standard.set(normalizedValue, forKey: _key)
		return true
	}

	static func clear() {
		UserDefaults.standard.removeObject(forKey: _key)
	}

	/// 校验并规范化：支持 40 位十六进制（旧机型）与 25 位带连字符（iPhone X 及以后，去掉连字符后 24 位）
	static func normalized(_ raw: String) -> String? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !trimmed.isEmpty else { return nil }
		let allowed = CharacterSet(charactersIn: "0123456789abcdef-")
		guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
		let digitsOnly = trimmed.replacingOccurrences(of: "-", with: "")
		guard digitsOnly.count == 40 || digitsOnly.count == 24 else { return nil }
		return trimmed
	}

	/// 「如何获取 UDID」说明（录入页展示）
	static let guidance = """
	获取 UDID 的方式（任选其一）：

	1. 电脑端（最可靠）
	   · Windows：安装爱思助手或 iTunes，连接手机后在「设备信息」里复制 UDID；
	   · Mac：Finder 连接手机，点设备信息处可看到并复制 UDID。

	2. 既有签名工具
	   如果你之前用过其他签名工具注册过这台设备，可在其设备信息页复制 UDID。

	3. 手机浏览器
	   打开任意「UDID 查询」网页，按提示安装描述文件后获取（部分新系统版本已不支持此方式）。

	UDID 只保存在本机，仅用于向 Apple 注册设备以便安装自签名应用。
	"""
}
