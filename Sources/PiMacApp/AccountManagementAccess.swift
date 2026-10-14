/// 打开管理与更改会话授权是不同权限；运行和排队不阻止浏览管理界面。
enum AccountManagementAccess {
  static func canOpen(
    hasAvailableSession: Bool, isLoadingConfiguration: Bool, isAlreadyPresenting: Bool
  ) -> Bool {
    hasAvailableSession && !isLoadingConfiguration && !isAlreadyPresenting
  }
}
