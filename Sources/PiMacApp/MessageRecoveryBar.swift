import AppKit
import SwiftUI

/// 预留固定一行，检查中与失败状态不挤动编辑器；次要操作只在详情中展开。
struct MessageRecoveryBar: View {
  @ObservedObject var app: AppModel
  @State private var showingDetails = false
  @State private var showingMigration = false
  @State private var showingTakeBack = false
  @State private var showingStop = false

  private var records: [OutboxMessage] { app.recoveryRecords }
  private var canMigrate: Bool {
    !records.isEmpty && records.allSatisfy { $0.state == .missing }
  }
  private var actionTitle: String {
    if records.first?.state == .conflict { return "查看冲突" }
    if canMigrate { return "在新会话继续" }
    if records.first?.state == .rejected && app.recoveryChecked { return "取回原稿" }
    return app.recoveryReady ? "继续发送" : "检查并恢复"
  }
  private var title: String {
    if let failure = app.deliveryStorageFailure { return failure }
    if app.isCheckingDelivery { return "正在核对 Server 接收情况，不会重复发送…" }
    guard let first = records.first else { return "" }
    return "\(records.count) 条输入待恢复 · \(first.issue)"
  }

  var body: some View {
    HStack(spacing: 8) {
      if !title.isEmpty {
        Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        Text(title)
          .font(.system(size: 12))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(title)
        Spacer(minLength: 8)
        Button("详情") { showingDetails = true }
          .popover(isPresented: $showingDetails) { details }
        if app.deliveryStorageFailure != nil {
          Button("重新检查保存") { app.retryDeliveryStorage() }.disabled(app.isBusy)
        } else if records.contains(where: { $0.state != .draft }) {
          Button(actionTitle) {
            if records.first?.state == .conflict {
              showingDetails = true
            } else if canMigrate {
              showingMigration = true
            } else if records.first?.state == .rejected && app.recoveryChecked {
              showingTakeBack = true
            } else if app.recoveryReady {
              app.continueDeliveryRecovery()
            } else {
              app.checkDeliveryRecovery()
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(app.isCheckingDelivery || app.isBusy)
        }
      }
    }
    .controlSize(.small)
    .frame(height: 32)
    .padding(.horizontal, 10)
    .sheet(isPresented: $showingMigration) {
      VStack(alignment: .leading, spacing: 16) {
        Text("在新会话继续").font(.headline)
        Text("仅携带可读取的历史文字、待处理原稿和保留附件。旧会话的完整上下文及运行状态无法保证恢复；旧请求可能已产生外部副作用。")
          .font(.callout)
          .foregroundStyle(.secondary)
        ScrollView {
          Text(app.migrationPreview)
            .font(.system(size: 12))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        HStack {
          Spacer()
          Button("取消", role: .cancel) { showingMigration = false }
          Button("确认迁移并继续") {
            showingMigration = false
            app.migrateDeliveryRecovery()
          }
          .buttonStyle(.borderedProminent)
          .disabled(!canMigrate || app.isBusy)
        }
      }
      .padding(24)
      .frame(width: 600, height: 480)
    }
    .alert("停止本地恢复？", isPresented: $showingStop) {
      Button("取消", role: .cancel) {}
      Button("保留记录，停止恢复") { app.stopDeliveryRecovery() }
    } message: {
      Text("本机原稿和附件继续保留，但不会再尝试投递。这不会取消或撤销 Server 中可能已经执行的任务。")
    }
    .alert("取回原稿不等于撤销请求", isPresented: $showingTakeBack) {
      Button("取消", role: .cancel) {}
      Button("取回原稿") { app.takeBackDeliveryDraft() }
    } message: {
      Text("旧请求可能已经被 Server 接收。原稿会放回空白输入框；重新发送前，请先核验是否已执行，避免重复操作。")
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("消息恢复").font(.headline)
      if let failure = app.deliveryStorageFailure {
        Text(failure).foregroundStyle(.red)
        if let directory = app.deliveryCoordinator?.store.storageDirectory {
          Button("打开原始发件箱") { NSWorkspace.shared.open(directory) }
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(records) { record in
            VStack(alignment: .leading, spacing: 4) {
              Text(record.text).lineLimit(4)
              Text(record.issue).foregroundStyle(.secondary)
              if !record.attachments.isEmpty {
                Text("已保留 \(record.attachments.count) 个附件").foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .font(.system(size: 12))
        .textSelection(.enabled)
      }
      .frame(maxHeight: 240)
      HStack {
        Button("复制文字") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            app.deliveryCoordinator?.store.exportText(records) ?? "", forType: .string)
        }
        .disabled(records.isEmpty)
        Button("导出原稿与附件…") { app.exportDeliveryRecovery() }
          .disabled(records.isEmpty)
        Spacer()
        Button("取回第一条原稿") {
          showingDetails = false
          showingTakeBack = true
        }
        .disabled(!app.canTakeBackDeliveryDraft)
      }
      Button("保留记录，停止本地恢复…") {
        showingDetails = false
        showingStop = true
      }
      .disabled(records.isEmpty || app.isBusy)
      Text("取回、导出均不会取消 Server 中可能已接收的任务。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 420)
  }
}
