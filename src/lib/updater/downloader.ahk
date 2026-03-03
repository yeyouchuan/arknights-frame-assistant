; == 更新下载器（支持取消）==

class UpdateDownloader {
    ; 取消标志
    static IsCancelled := false
    ; HTTP请求对象（用于中止）
    static CurrentHttp := ""
    
    ; 取消当前下载
    static Cancel() {
        this.IsCancelled := true
        ; 尝试中止HTTP请求
        if (this.CurrentHttp != "") {
            try {
                this.CurrentHttp.Abort()
            }
        }
    }
    
    ; 重置取消状态（开始新下载前调用）
    static ResetCancel() {
        this.IsCancelled := false
        this.CurrentHttp := ""
    }
    
    ; 下载文件
    ; params: 包含以下字段的对象
    ;   - downloadUrl: 下载链接
    ;   - localVersion: 当前版本
    ;   - remoteVersion: 远程版本
    ;   - onProgress: 进度回调函数(可选)
    ;   - onComplete: 完成回调函数
    ;   - onError: 错误回调函数
    ;   - onCancel: 取消回调函数(可选)
    static Download(params) {
        ; 重置取消状态
        this.ResetCancel()
        
        downloadUrl := params.downloadUrl
        remoteVersion := params.remoteVersion
        
        ; 生成临时文件路径
        tempDir := A_Temp "\ArknightsFrameAssistant"
        if !DirExist(tempDir)
            DirCreate(tempDir)
        
        tempFile := tempDir "\AFA_" remoteVersion "_update.exe"
        
        try {
            ; 使用 WinHttpRequest 进行下载
            http := ComObject("WinHttp.WinHttpRequest.5.1")
            this.CurrentHttp := http
            http.Open("GET", downloadUrl, true)
            http.Send()
            http.WaitForResponse()
            
            ; 检查是否已取消
            if (this.IsCancelled) {
                ; 取消下载，清理临时文件
                if (FileExist(tempFile)) {
                    try FileDelete(tempFile)
                }
                ; 调用取消回调
                if (params.HasProp("onCancel") && (Type(params.onCancel) = "Func" || Type(params.onCancel) = "Closure")) {
                    callback := params.onCancel
                    callback.Call({message: "用户取消了下载"})
                }
                return {success: false, error: "用户取消了下载", cancelled: true}
            }
            
            ; 检查HTTP状态
            if (http.Status != 200) {
                throw Error("HTTP错误: " http.Status " - " http.StatusText)
            }
            
            ; 再次检查是否已取消（在保存文件前）
            if (this.IsCancelled) {
                if (FileExist(tempFile)) {
                    try FileDelete(tempFile)
                }
                if (params.HasProp("onCancel") && (Type(params.onCancel) = "Func" || Type(params.onCancel) = "Closure")) {
                    callback := params.onCancel
                    callback.Call({message: "用户取消了下载"})
                }
                return {success: false, error: "用户取消了下载", cancelled: true}
            }
            
            ; 获取响应体并保存到文件
            responseBody := http.ResponseBody
            adodb := ComObject("ADODB.Stream")
            adodb.Type := 1  ; 二进制模式
            adodb.Open()
            adodb.Write(responseBody)
            adodb.SaveToFile(tempFile, 2)  ; 2 = 覆盖模式
            adodb.Close()
            
            ; 再次检查是否已取消（在验证前）
            if (this.IsCancelled) {
                if (FileExist(tempFile)) {
                    try FileDelete(tempFile)
                }
                if (params.HasProp("onCancel") && (Type(params.onCancel) = "Func" || Type(params.onCancel) = "Closure")) {
                    callback := params.onCancel
                    callback.Call({message: "用户取消了下载"})
                }
                return {success: false, error: "用户取消了下载", cancelled: true}
            }
            
            ; 验证文件是否成功创建
            if !FileExist(tempFile) {
                throw Error("文件保存失败")
            }
            
            ; 发布下载完成事件
            EventBus.Publish("UpdateDownloadComplete", {
                tempFile: tempFile,
                remoteVersion: remoteVersion
            })
            
            ; 调用完成回调（如果提供且是函数）
            if (params.HasProp("onComplete") && (Type(params.onComplete) = "Func" || Type(params.onComplete) = "Closure")) {
                callback := params.onComplete
                callback.Call({
                    tempFile: tempFile,
                    remoteVersion: remoteVersion
                })
            }
            
            return {
                success: true,
                tempFile: tempFile,
                remoteVersion: remoteVersion
            }
            
        } catch Error as e {
            ; 检查是否是取消导致的错误
            if (this.IsCancelled) {
                if (params.HasProp("onCancel") && (Type(params.onCancel) = "Func" || Type(params.onCancel) = "Closure")) {
                    callback := params.onCancel
                    callback.Call({message: "用户取消了下载"})
                }
                return {success: false, error: "用户取消了下载", cancelled: true}
            }
            
            errorInfo := {
                message: "下载失败: " e.Message,
                url: downloadUrl,
                version: remoteVersion
            }
            
            ; 发布下载错误事件
            EventBus.Publish("UpdateDownloadError", errorInfo)
            
            ; 调用错误回调（如果提供且是函数）
            if (params.HasProp("onError") && (Type(params.onError) = "Func" || Type(params.onError) = "Closure")) {
                callback := params.onError
                callback.Call(errorInfo)
            }
            
            return {
                success: false,
                error: errorInfo.message
            }
        } finally {
            ; 清理HTTP引用
            this.CurrentHttp := ""
        }
    }
    
    ; 获取临时文件路径（用于检查之前的下载）
    static GetTempFilePath(version) {
        tempDir := A_Temp "\ArknightsFrameAssistant"
        return tempDir "\AFA_" version "_update.exe"
    }
    
    ; 验证下载的文件是否完整（简单的存在性检查）
    static VerifyDownload(filePath) {
        if !FileExist(filePath) {
            return false
        }
        
        ; 获取文件大小
        try {
            fileSize := FileGetSize(filePath)
            return fileSize > 0
        } catch {
            return false
        }
    }
}
