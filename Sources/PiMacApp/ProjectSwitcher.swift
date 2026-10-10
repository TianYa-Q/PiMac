import SwiftUI

/// A content-sized trigger and bounded popover, independent of composer width.
struct ProjectSwitcher: View {
  static let triggerHeight: CGFloat = 28

  let projects: [WorkspaceProject]
  let selectedProject: WorkspaceProject?
  let onSelect: (WorkspaceProject) -> Void

  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "folder")
          .foregroundStyle(Color.accentColor)
        Text(selectedProject?.name ?? "选择项目")
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .font(.system(size: 12, weight: .medium))
      .padding(.horizontal, 10)
      .frame(height: Self.triggerHeight)
      .background(Color.primary.opacity(0.045), in: Capsule())
      .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityLabel("切换项目，当前：\(selectedProject?.name ?? "未选择")")
    .popover(isPresented: $isPresented, arrowEdge: .top) {
      VStack(alignment: .leading, spacing: 8) {
        Text("切换项目")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.top, 4)
        ScrollView {
          VStack(spacing: 3) {
            ForEach(projects) { project in
              ProjectSwitcherRow(project: project, selected: project.id == selectedProject?.id) {
                isPresented = false
                onSelect(project)
              }
            }
          }
        }
        .frame(height: min(CGFloat(projects.count) * 52, 280))
      }
      .padding(8)
      .frame(width: 300)
    }
  }
}

private struct ProjectSwitcherRow: View {
  let project: WorkspaceProject
  let selected: Bool
  let action: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "folder")
          .font(.system(size: 15))
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .frame(width: 28, height: 30)
          .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        VStack(alignment: .leading, spacing: 3) {
          Text(project.name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
          Text(project.url.path)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .truncationMode(.middle)
        }
        .lineLimit(1)
        Spacer(minLength: 4)
        if selected {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        selected ? Color.accentColor.opacity(0.09)
          : isHovered ? Color.primary.opacity(0.05) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8))
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(project.url.path)
    .accessibilityLabel("\(project.name)\(selected ? "，已选中" : "")")
  }
}
