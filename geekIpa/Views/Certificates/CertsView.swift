//
//  CertsView.swift
//  geekIpa
//
//  证书页（规格书 §3）：证书列表 + 类型徽标 + 有效期着色 + 导入流程 +
//  操作弹窗（查看证书 / 查看描述文件 / 导出 P12 / 删除）+ 空状态。
//
//  CONTRACT: Tab 框架直接引用 `CertsView()`，签名勿改。
//  与 Settings 里的旧版 CertificatesView 共存，互不影响。
//

import SwiftUI
import CoreData

// CONTRACT: 公共契约 —— Tab 框架直接引用
struct CertsView: View {
	init() {}

	// MARK: Fetch（全量证书，按导入时间倒序）
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .default
	) private var _certificates: FetchedResults<CertificatePair>

	// MARK: 状态
	@State private var _actionCert: CertificatePair?       // 操作弹窗对象
	@State private var _detailCert: CertificatePair?       // push 证书详情
	@State private var _profileCert: CertificatePair?      // push 描述文件详情
	@State private var _exportCert: CertificatePair?       // 导出 sheet
	@State private var _deleteCert: CertificatePair?       // 删除确认（第一次）
	@State private var _deleteFinalCert: CertificatePair?  // 删除确认（被引用时第二次）
	@State private var _importTypeDialog = false           // 导入类型选择
	@State private var _importKind: GeekCertKind?          // 文件导入表单（UDID/企业）
	@State private var _showAppleIDAccount = false         // push Apple ID 账号页
	@State private var _highlightUUID: String?             // 导入成功后高亮 2 秒
	@State private var _errorMessage: String?              // 失败原因弹窗

	private var _errorPresenting: Binding<Bool> {
		Binding(
			get: { _errorMessage != nil },
			set: { if !$0 { _errorMessage = nil } }
		)
	}

	// MARK: Body（拆分为多层计算属性，避免 Swift 类型检查超时）

	var body: some View {
		_withDeleteConfirm
	}

	// MARK: 1. 列表 + 导航 + 操作弹窗 + push 目标

	private var _baseList: some View {
		List {
			_listContent
			_slotSection
		}
		.listStyle(.insetGrouped)
		.navigationTitle("证书")
		.toolbar { _importToolbar }
		.confirmationDialog(
			_actionTitle,
			isPresented: _actionPresenting,
			titleVisibility: .visible
		) {
			_actionButtons
		}
		.navigationDestination(isPresented: _detailPresenting) {
			if let cert = _detailCert { CertsCertDetailView(cert: cert) }
		}
		.navigationDestination(isPresented: _profilePresenting) {
			if let cert = _profileCert { CertsProfileDetailView(cert: cert) }
		}
		.navigationDestination(isPresented: $_showAppleIDAccount) {
			AppleIDAccountView()
		}
		.sheet(item: $_exportCert) { cert in
			CertsExportView(cert: cert)
		}
	}

	// MARK: 2. 导入流程 + 删除确认

	private var _withImportAndDelete: some View {
		_baseList
			.confirmationDialog("选择证书类型", isPresented: $_importTypeDialog, titleVisibility: .visible) {
				_importTypeButtons
			} message: {
				Text("UDID / 企业证书从文件导入；Apple ID 证书登录账号后自动生成。")
			}
			.sheet(item: $_importKind) { kind in
				CertsImportView(kind: kind) { newUUID in
					_highlightNewCertificate(uuid: newUUID)
				}
			}
			.alert("删除证书", isPresented: _deletePresenting, presenting: _deleteCert) { cert in
				_deleteButtons(for: cert)
			} message: { cert in
				_deleteMessage(for: cert)
			}
	}

	// MARK: 3. 二次删除确认 + 错误提示

	private var _withDeleteConfirm: some View {
		_withImportAndDelete
			.alert("再次确认删除", isPresented: _deleteFinalPresenting, presenting: _deleteFinalCert) { cert in
				Button("取消", role: .cancel) {}
				Button("删除", role: .destructive) {
					Storage.shared.deleteCertificate(for: cert)
				}
			} message: { cert in
				Text("该证书正在被 \(cert.signedApps?.count ?? 0) 个应用使用，删除后这些应用将无法安装。确定删除？")
			}
			.alert("提示", isPresented: _errorPresenting) {
				Button("好", role: .cancel) {}
			} message: {
				Text(_errorMessage ?? "")
			}
	}

	// MARK: - 片段

	@ViewBuilder
	private var _listContent: some View {
		if _certificates.isEmpty {
			Section {
				_emptyState
					.frame(maxWidth: .infinity)
					.listRowBackground(Color.clear)
			}
		} else {
			Section {
				ForEach(_certificates, id: \.uuid) { cert in
					_rowButton(for: cert)
				}
			}
		}
	}

	private var _slotSection: some View {
		Section {
			NavigationLink {
				SlotStatusView()
			} label: {
				Label("免费名额管理", systemImage: "rectangle.3.group")
			}
		} footer: {
			Text("使用免费 Apple ID 签名的应用最多同时激活 3 个，可在名额页查看与释放。")
		}
	}

	@ToolbarContentBuilder
	private var _importToolbar: some ToolbarContent {
		ToolbarItem(placement: .navigationBarTrailing) {
			Button("导入证书") {
				_importTypeDialog = true
			}
			.font(.body.weight(.semibold))
			.tint(.geekPrimary)
		}
	}

	private var _actionTitle: String {
		_actionCert?.nickname ?? "证书操作"
	}

	@ViewBuilder
	private var _actionButtons: some View {
		Button("查看证书") {
			if let cert = _actionCert { _detailCert = cert }
		}
		Button("查看描述文件") {
			if let cert = _actionCert { _profileCert = cert }
		}
		Button("导出 P12") {
			if let cert = _actionCert { _exportCert = cert }
		}
		Button("删除", role: .destructive) {
			if let cert = _actionCert { _deleteCert = cert }
		}
		Button("取消", role: .cancel) {}
	}

	@ViewBuilder
	private var _importTypeButtons: some View {
		Button("UDID 证书") { _importKind = .udid }
		Button("Apple ID 证书") { _showAppleIDAccount = true }
		Button("企业证书") { _importKind = .enterprise }
		Button("取消", role: .cancel) {}
	}

	@ViewBuilder
	private func _deleteButtons(for cert: CertificatePair) -> some View {
		Button("取消", role: .cancel) {}
		if (cert.signedApps?.count ?? 0) > 0 {
			Button("继续", role: .destructive) {
				_deleteFinalCert = cert
			}
		} else {
			Button("删除", role: .destructive) {
				Storage.shared.deleteCertificate(for: cert)
			}
		}
	}

	@ViewBuilder
	private func _deleteMessage(for cert: CertificatePair) -> some View {
		let count = cert.signedApps?.count ?? 0
		if count > 0 {
			Text("该证书正在被 \(count) 个应用使用，删除后这些应用将无法安装。")
		} else {
			Text("将同时删除本机保存的证书文件与描述文件，此操作不可撤销。")
		}
	}

	// MARK: - Binding 辅助（避免内联闭包拖慢类型检查）

	private var _actionPresenting: Binding<Bool> {
		Binding(get: { _actionCert != nil }, set: { if !$0 { _actionCert = nil } })
	}

	private var _detailPresenting: Binding<Bool> {
		Binding(get: { _detailCert != nil }, set: { if !$0 { _detailCert = nil } })
	}

	private var _profilePresenting: Binding<Bool> {
		Binding(get: { _profileCert != nil }, set: { if !$0 { _profileCert = nil } })
	}

	private var _deletePresenting: Binding<Bool> {
		Binding(get: { _deleteCert != nil }, set: { if !$0 { _deleteCert = nil } })
	}

	private var _deleteFinalPresenting: Binding<Bool> {
		Binding(get: { _deleteFinalCert != nil }, set: { if !$0 { _deleteFinalCert = nil } })
	}

	// MARK: - 空状态（§5：SF Symbol + 说明 + 主操作按钮）
	@ViewBuilder
	private var _emptyState: some View {
		VStack(spacing: 16) {
			Image(systemName: "checkmark.shield")
				.font(.system(size: 52, weight: .regular))
				.foregroundStyle(.secondary)
			Text("暂无证书")
				.font(.title3.weight(.semibold))
			Text("导入签名证书后即可开始为应用签名")
				.font(.footnote)
				.foregroundStyle(.secondary)
			Button {
				_importTypeDialog = true
			} label: {
				Text("导入证书")
					.padding(.horizontal, 12)
			}
			.buttonStyle(.borderedProminent)
			.tint(.geekPrimary)
		}
		.padding(24)
	}

	// MARK: - 列表行
	@ViewBuilder
	private func _rowButton(for cert: CertificatePair) -> some View {
		Button {
			_actionCert = cert
		} label: {
			_CertRow(cert: cert)
		}
		.buttonStyle(.plain)
		.listRowBackground(
			(cert.uuid != nil && cert.uuid == _highlightUUID)
				? Color.geekPrimary.opacity(0.12)
				: Color.geekCardBackground
		)
	}

	// MARK: - 导入成功高亮 2 秒
	private func _highlightNewCertificate(uuid: String?) {
		_highlightUUID = uuid
		GeekToast.show("证书导入成功")
		Task {
			try? await Task.sleep(nanoseconds: 2_000_000_000)
			await MainActor.run { _highlightUUID = nil }
		}
	}
}

// MARK: - 证书行

private struct _CertRow: View {
	let cert: CertificatePair

	@State private var _decoded: Certificate?
	@State private var _x509: GeekX509Info?

	private var _kind: GeekCertKind { GeekCertKind(cert: cert) }

	private var _title: String {
		cert.nickname ?? _decoded?.Name ?? "未知证书"
	}

	private var _expiry: GeekCertExpiryState {
		GeekCertExpiryState(expiration: cert.expiration ?? _decoded?.ExpirationDate)
	}

	private var _isRevoked: Bool { cert.revoked }

	var body: some View {
		let expiry = _expiry
		VStack(alignment: .leading, spacing: 6) {
			// 名称 + 类型徽标
			HStack(alignment: .center, spacing: 8) {
				Text(_title)
					.font(.body.weight(.semibold))
					.foregroundStyle(expiry.isExpired ? Color.secondary : Color.primary)
					.lineLimit(1)
				Spacer(minLength: 4)
				_badge(_kind.title, color: _kind.color)
			}

			// Team ID + 序列号
			Text("Team ID：\(_decoded?.TeamIdentifier.first ?? "—")　序列号：\(_x509?.serialNumber ?? "—")")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(1)

			// 有效期起止 + 剩余天数
			HStack {
				Text("\(GeekDateFormat.dayString(_decoded?.CreationDate)) － \(GeekDateFormat.dayString(cert.expiration ?? _decoded?.ExpirationDate))")
					.font(.footnote)
					.foregroundStyle(.secondary)
				Spacer(minLength: 4)
				if let remaining = expiry.remainingText {
					Text(remaining)
						.font(.footnote.weight(.semibold))
						.foregroundStyle(expiry.color)
				}
			}

			// 状态标签
			let isSoon = { if case .expiringSoon = expiry { return true }; return false }()
			if expiry.isExpired || _isRevoked || isSoon {
				HStack(spacing: 6) {
					if expiry.isExpired {
						_tag("已过期", color: .geekDanger)
					} else if isSoon {
						_tag("即将过期", color: .geekWarning)
					}
					if _isRevoked {
						_tag("已吊销", color: .geekDanger)
					}
				}
			}
		}
		.padding(.vertical, 4)
		.onAppear {
			_decoded = Storage.shared.getProvisionFileDecoded(for: cert)
			_x509 = GeekX509Info(derData: _decoded?.DeveloperCertificates?.first)
		}
	}

	@ViewBuilder
	private func _badge(_ title: String, color: Color) -> some View {
		Text(title)
			.font(.caption2.weight(.semibold))
			.foregroundStyle(color)
			.padding(.horizontal, 8)
			.padding(.vertical, 3)
			.background(color.opacity(0.14))
			.clipShape(Capsule())
	}

	@ViewBuilder
	private func _tag(_ title: String, color: Color) -> some View {
		Text(title)
			.font(.caption2)
			.foregroundStyle(color)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.overlay(
				RoundedRectangle(cornerRadius: 4, style: .continuous)
					.strokeBorder(color, lineWidth: 1)
			)
	}
}
