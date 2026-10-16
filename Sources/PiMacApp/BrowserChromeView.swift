import AppKit
import SwiftUI

struct BrowserPreviewPanel: View {
  @ObservedObject var model: BrowserPreviewModel
  @Environment(\.colorScheme) private var colorScheme
  @State private var sidebarOverride: Bool?
  @State private var address = ""
  @State private var prompt = ""
  @FocusState private var addressFocused: Bool

  private var ownerLabel: String {
    guard model.control.canOperate else { return "等待连接" }
    switch model.control.owner {
    case .you: return "你正在浏览"
    case .agent: return "代理正在浏览"
    case .anotherViewer: return "其他窗口正在操作"
    case .unclaimed: return "准备就绪"
    }
  }

  var body: some View {
    GeometryReader { geometry in
      let expanded =
        sidebarOverride
        ?? BrowserChromeLayout.defaultsToExpanded(availableWidth: geometry.size.width)
      let sidebarWidth = BrowserChromeLayout.sidebarWidth(
        availableWidth: geometry.size.width, expanded: expanded)
      let floating = BrowserChromeLayout.usesOverlay(
        availableWidth: geometry.size.width, expanded: expanded)
      let compact = geometry.size.width - (floating ? 0 : sidebarWidth) < 560
      HStack(spacing: 0) {
        if !floating {
          tabSidebar(expanded: expanded, floating: false).frame(width: sidebarWidth)
        }
        VStack(spacing: 0) {
          navigationBar(expanded: expanded, compact: compact)
          page
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
              RoundedRectangle(cornerRadius: 12).strokeBorder(
                Color.primary.opacity(0.065), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.04), radius: 5, y: 2)
            .padding(.horizontal, 8).padding(.bottom, 8)
          if let dialog = model.control.dialog { dialogView(dialog) }
          if let failure = model.selectedTab?.failure { status("页面加载失败：\(failure)") }
          if let error = model.listError { status(error) }
          if let notice = model.notice { status(notice) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .overlay(alignment: .leading) {
        if floating {
          // 窄面板展开标签时临时覆盖网页，而不是把网页和工具栏挤到无法操作。
          tabSidebar(expanded: true, floating: true).frame(
            width: min(208, geometry.size.width * 0.7)
          )
          .background(Color(nsColor: .windowBackgroundColor))
          .compositingGroup()
          .shadow(color: .black.opacity(0.12), radius: 12, x: 4)
        }
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onChange(of: model.selectedTab?.id) { _, _ in
      addressFocused = false
      address = model.selectedTab?.url ?? ""
    }
    .onChange(of: model.selectedTab?.url, initial: true) { _, value in
      if !addressFocused { address = value ?? "" }
    }
    .onChange(of: model.control.isControlling) { _, controlling in
      if !controlling {
        addressFocused = false
        address = model.selectedTab?.url ?? ""
      }
    }
    .onChange(of: model.control.dialog, initial: true) { _, value in
      prompt = value?.defaultValue ?? ""
    }
  }

  private func tabSidebar(expanded: Bool, floating: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 9) {
        if floating {
          BrowserChromeButton(symbol: "sidebar.left", label: "收起标签栏") { sidebarOverride = false }
        } else {
          Image(systemName: "globe")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
        }
        if expanded {
          Text("浏览器").font(.system(size: 13, weight: .semibold))
          Spacer(minLength: 0)
          Text("\(model.tabs.count)").font(.system(size: 11, design: .rounded))
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, expanded ? 12 : 13)
      .frame(height: 56)
      ScrollView {
        LazyVStack(spacing: 4) {
          ForEach(model.tabs) { tab in
            BrowserTabRow(
              tab: tab, selected: tab.id == model.selectedTab?.id,
              expanded: expanded, canClose: model.canManageTabs,
              select: {
                model.select(tab.id)
                if floating { sidebarOverride = false }
              },
              close: { model.updateTabs(closing: tab.id) })
          }
          Button {
            model.updateTabs(closing: nil)
          } label: {
            HStack(spacing: 10) {
              if model.isUpdatingTabs {
                ProgressView().controlSize(.mini).frame(width: 24)
              } else {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 24)
              }
              if expanded {
                Text("新标签页").font(.system(size: 12))
                Spacer(minLength: 0)
              }
            }
            .foregroundStyle(.secondary).padding(.horizontal, expanded ? 8 : 0)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(RoundedRectangle(cornerRadius: 9))
          }
          .buttonStyle(.plain).disabled(!model.canManageTabs)
          .help("新建浏览器标签页").accessibilityLabel("新建浏览器标签页")
          .padding(.top, 6)
        }
        .padding(.horizontal, 8).padding(.top, 4)
      }
      .scrollIndicators(.hidden)
      HStack(spacing: 7) {
        Circle().fill(model.control.isControlling ? Color.green : Color.secondary.opacity(0.5))
          .frame(width: 5, height: 5)
        if expanded {
          Text(ownerLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 0)
        }
      }
      .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 16)
      .help(ownerLabel)
    }
    .background(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.025))
  }

  private func navigationBar(expanded: Bool, compact: Bool) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: compact ? 2 : 3) {
        BrowserChromeButton(symbol: "sidebar.left", label: expanded ? "收起标签栏" : "展开标签栏") {
          sidebarOverride = !expanded
        }
        HStack(spacing: 0) {
          BrowserChromeButton(symbol: "chevron.left", label: "后退") { model.send(.history(-1)) }
          BrowserChromeButton(symbol: "chevron.right", label: "前进") { model.send(.history(1)) }
          BrowserChromeButton(symbol: "arrow.clockwise", label: "刷新页面") { model.send(.reload) }
        }
        .disabled(!model.control.isControlling)
        if compact { Spacer(minLength: 2) } else { addressBar.padding(.horizontal, 8) }
        ownershipButton(compact: compact)
        Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1, height: 16).padding(
          .horizontal, 6)
        if model.detached {
          BrowserChromeButton(symbol: "sidebar.right", label: "停靠到右侧面板") { model.dock() }
        } else {
          BrowserChromeButton(symbol: "arrow.up.forward.square", label: "在独立窗口中打开") {
            model.detach()
          }
          .disabled(model.selectedTab == nil)
        }
        BrowserChromeButton(symbol: "xmark", label: "收起浏览器并交还控制权") { model.setVisible(false) }
      }
      .frame(height: 56).padding(.horizontal, 10)
      if compact { addressBar.padding(.horizontal, 12).padding(.bottom, 10) }
    }
  }

  private var addressBar: some View {
    HStack(spacing: 7) {
      Image(
        systemName: model.selectedTab.map { BrowserTabPresentation(tab: $0).isSecure } == true
          ? "lock.fill" : "globe"
      )
      .font(.system(size: 10)).foregroundStyle(.tertiary)
      if model.control.isControlling {
        TextField("输入网址", text: $address)
          .font(.system(size: 12)).textFieldStyle(.plain).focused($addressFocused)
          .onSubmit {
            model.send(.navigate(address))
            addressFocused = false
          }
          .onExitCommand {
            address = model.selectedTab?.url ?? ""
            addressFocused = false
          }
          .accessibilityLabel("浏览器网址")
      } else {
        Text(model.selectedTab?.url.isEmpty == false ? (model.selectedTab?.url ?? "") : "新标签页")
          .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("浏览器网址")
      }
    }
    .padding(.horizontal, 10).frame(height: 32)
    .frame(minWidth: 60, maxWidth: .infinity)
    .background(
      Color.primary.opacity(addressFocused ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8).strokeBorder(
        addressFocused ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.025),
        lineWidth: 1)
    }
    .contextMenu {
      Button("复制网址") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.selectedTab?.url ?? "", forType: .string)
      }
      .disabled(model.selectedTab?.url.isEmpty != false)
    }
  }

  private func ownershipButton(compact: Bool) -> some View {
    Button {
      model.send(model.control.isControlling ? .releaseControl : .takeControl)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: model.control.isControlling ? "checkmark.shield" : "cursorarrow")
          .font(.system(size: 11, weight: .medium))
        if !compact {
          Text(model.control.isControlling ? "交还代理" : "接管操作").font(
            .system(size: 11, weight: .medium))
        }
      }
      .foregroundStyle(model.control.isControlling ? Color.accentColor : Color.primary.opacity(0.8))
      .padding(.horizontal, compact ? 8 : 10).frame(height: 28)
      .background(
        model.control.isControlling
          ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 7)
      )
      .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .disabled(
      !model.control.isControlling && !T3BrowserInput.takeControl.isAllowed(by: model.control)
    )
    .help(model.control.isControlling ? "交还代理继续操作" : "接管后可点击、滚动和输入")
    .accessibilityLabel(model.control.isControlling ? "交还代理" : "接管操作")
  }

  private var page: some View {
    ZStack {
      BrowserPreviewCanvas(
        image: model.image, viewport: model.viewport,
        interactive: model.control.isControlling, send: model.send, resize: model.resize
      )
      .accessibilityLabel(model.selectedTab?.title ?? "浏览器画面")
      if model.tabs.isEmpty {
        welcome(title: "新的网页，新的开始", description: "新建一个标签，或让代理为你打开网页。", newTab: true)
      } else if let failure = model.failure {
        VStack(spacing: 12) {
          Image(systemName: "wifi.exclamationmark").font(.system(size: 26)).foregroundStyle(
            .secondary)
          Text(failure).font(.callout).multilineTextAlignment(.center)
          Button("重新连接") { model.reconnect() }.controlSize(.small)
        }
        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(
          16)
      } else if model.image == nil {
        ProgressView("正在连接网页…").controlSize(.small).font(.caption).foregroundStyle(.secondary)
      } else if model.selectedTab?.url.isEmpty == true {
        welcome(title: "新标签页", description: "输入网址，继续探索。", newTab: false)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func welcome(title: String, description: String, newTab: Bool) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "globe").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(
        .secondary
      )
      .frame(width: 64, height: 64)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
      Text(title).font(.system(size: 18, weight: .medium, design: .rounded))
      Text(description).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(
        .center)
      Button(newTab ? "新建标签页" : "输入网址") {
        if newTab { model.updateTabs(closing: nil) } else { addressFocused = true }
      }
      .buttonStyle(.bordered).controlSize(.small).padding(.top, 6)
      .disabled(newTab ? !model.canManageTabs : !model.control.isControlling)
    }
    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func dialogView(_ dialog: T3BrowserControl.Dialog) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(dialog.message).font(.callout).textSelection(.enabled)
      if dialog.type == "prompt" { TextField("输入内容", text: $prompt).textFieldStyle(.roundedBorder) }
      HStack {
        Spacer()
        Button("取消") { model.send(.dialog(accept: false, text: "")) }
        Button("确定") { model.send(.dialog(accept: true, text: prompt)) }.buttonStyle(
          .borderedProminent)
      }
      .controlSize(.small)
    }
    .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal, 8).padding(.bottom, 8).disabled(!model.control.isControlling)
  }

  private func status(_ text: String) -> some View {
    Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
  }
}

private struct BrowserTabRow: View {
  let tab: T3BrowserTab
  let selected: Bool
  let expanded: Bool
  let canClose: Bool
  let select: () -> Void
  let close: () -> Void
  @State private var hovering = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let display = BrowserTabPresentation(tab: tab)
    HStack(spacing: 0) {
      Button(action: select) {
        HStack(spacing: 9) {
          BrowserSiteMark(display: display, failed: tab.failure != nil)
          if expanded {
            VStack(alignment: .leading, spacing: 3) {
              Text(display.title).font(.system(size: 12, weight: selected ? .medium : .regular))
                .lineLimit(1).truncationMode(.tail)
              Text(display.site).font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
          }
        }
        .frame(
          maxWidth: .infinity, minHeight: expanded ? 46 : 40,
          alignment: expanded ? .leading : .center
        )
        .padding(.leading, expanded ? 8 : 0).contentShape(Rectangle())
      }
      .buttonStyle(.plain).help("\(display.title)\n\(tab.url)")
      .accessibilityLabel(display.title).accessibilityValue(selected ? "当前标签" : "")
      if expanded {
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(
            width: 22, height: 28)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 4)
        .opacity(selected || hovering ? 1 : 0).allowsHitTesting(selected || hovering)
        .disabled(!canClose).help("关闭标签页").accessibilityLabel("关闭 \(display.title)")
      }
    }
    .background(
      selected
        ? (colorScheme == .dark
          ? Color.white.opacity(0.075) : Color(nsColor: .controlBackgroundColor))
        : hovering ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 9)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9).strokeBorder(
        Color.primary.opacity(selected ? 0.045 : 0), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(selected ? 0.055 : 0), radius: 3, y: 2)
    .onHover { hovering = $0 }
    .contextMenu { Button("关闭标签页", action: close).disabled(!canClose) }
  }
}

private struct BrowserSiteMark: View {
  let display: BrowserTabPresentation
  let failed: Bool
  private let colors: [Color] = [.blue, .indigo, .teal, .orange, .purple, .pink]

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7).fill(colors[display.colorIndex].opacity(0.12))
      if failed {
        Image(systemName: "exclamationmark").font(.system(size: 12, weight: .semibold))
      } else if display.monogram.isEmpty {
        Image(systemName: "globe").font(.system(size: 13))
      } else {
        Text(display.monogram).font(.system(size: 12, weight: .semibold, design: .rounded))
      }
    }
    .foregroundStyle(failed ? .orange : colors[display.colorIndex])
    .frame(width: 24, height: 24)
  }
}

private struct BrowserChromeButton: View {
  let symbol: String
  let label: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12, weight: .regular))
        .frame(width: 28, height: 28)
        .background(
          Color.primary.opacity(hovering ? 0.065 : 0), in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain).foregroundStyle(.secondary)
    .onHover { hovering = $0 }.help(label).accessibilityLabel(label)
  }
}
