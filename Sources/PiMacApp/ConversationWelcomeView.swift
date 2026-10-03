import SwiftUI

struct ConversationWelcomeView: View {
  let project: String?
  let chooseProject: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Image(systemName: "terminal")
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .padding(15)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
      VStack(alignment: .leading, spacing: 8) {
        Text(project == nil ? "从一个项目开始" : "今天要构建什么？")
          .font(.system(size: 28, weight: .bold, design: .rounded))
        Text(project.map { "在 \($0) 中探索代码、实现功能或排查问题。" } ?? "选择项目目录，让 Pi 了解你的工作区。")
          .font(.callout).foregroundStyle(.secondary)
      }
      if project == nil {
        Button("选择项目…", systemImage: "folder.badge.plus", action: chooseProject)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(28).frame(maxWidth: 620, alignment: .leading)
    .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
  }
}
