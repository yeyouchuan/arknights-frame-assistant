; == 更新公告内容数据 ==

class ChangelogData {
    static VersionList := Map(
        Version.Get(), {
            newFeatures: [
                
            ],
            improvements: [
                
            ],
            bugFixes: [
                "修复了部分涉及左键点击的功能在游戏更新后失效的问题"
            ]
        }
    )

    static GetContent(version) {
        if this.VersionList.Has(version)
            return this.VersionList[version]
        return {newFeatures: [], improvements: [], bugFixes: []}
    }

    static HasContent(version) {
        content := this.GetContent(version)
        return content.newFeatures.Length > 0 
            || content.improvements.Length > 0 
            || content.bugFixes.Length > 0
    }
}
