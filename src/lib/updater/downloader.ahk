; == 更新下载器（支持取消）==
; 新增：支持下载进度回调

class UpdateDownloader {
    ; 取消标志
    static IsCancelled := false
    ; HTTP请求对象（用于中止）
    static CurrentHttp := ""
    ; 当前下载会话（用于异步分块下载与进度上报）
    static CurrentSession := ""
    
    ; 取消当前下载
    static Cancel() {
        this.IsCancelled := true
        ; 尝试中止HTTP请求
        if (this.CurrentSession != "") {
            this.CurrentSession.Cancel()
            return
        }
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
        this.CurrentSession := ""
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
            ; 检查是否已取消
            ; 检查HTTP状态
            ; 再次检查是否已取消（在保存文件前）
            ; 获取响应体并保存到文件
            ; 再次检查是否已取消（在验证前）
            ; 验证文件是否成功创建
            ; 发布下载完成事件
            ; 调用完成回调（如果提供且是函数）
            ; 新实现：以上流程改为异步事件驱动下载，由下载会话对象分块写入文件并上报进度
            session := UpdateDownloadSession(params, downloadUrl, tempFile, remoteVersion)
            this.CurrentSession := session
            session.Start()
            while !session.IsDone
                Sleep(50)
            return session.Result
            
        } catch Error as e {
            ; 检查是否是取消导致的错误
            if (this.IsCancelled) {
                if (params.HasProp("onCancel") && (Type(params.onCancel) = "Func" || Type(params.onCancel) = "Closure" || Type(params.onCancel) = "BoundFunc")) {
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
            if (params.HasProp("onError") && (Type(params.onError) = "Func" || Type(params.onError) = "Closure" || Type(params.onError) = "BoundFunc")) {
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
            this.CurrentSession := ""
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

; 下载会话：负责异步分块下载、进度上报和取消清理
class UpdateDownloadSession {
    __New(params, downloadUrl, tempFile, remoteVersion) {
        this.Params := params
        this.DownloadUrl := downloadUrl
        this.TempFile := tempFile
        this.RemoteVersion := remoteVersion
        this.Http := ""
        this.FileObj := ""
        this.IsDone := false
        this.IsCancelled := false
        this.TotalBytes := 0
        this.DownloadedBytes := 0
        this.HasContentLength := false
        this.Result := {success: false, error: "下载未开始"}
    }

    ; 启动异步下载
    Start() {
        if FileExist(this.TempFile) {
            try FileDelete(this.TempFile)
        }

        this.FileObj := FileOpen(this.TempFile, "w")
        if !IsObject(this.FileObj)
            throw Error("无法创建临时文件")

        this.Http := ComObject("WinHttp.WinHttpRequest.5.1")
        UpdateDownloader.CurrentHttp := this.Http
        ComObjConnect(this.Http, this)
        this.Http.Open("GET", this.DownloadUrl, true)
        this.Http.Send()
    }

    ; 取消下载
    Cancel() {
        if (this.IsDone || this.IsCancelled)
            return

        this.IsCancelled := true
        UpdateDownloader.IsCancelled := true

        if (this.Http != "") {
            try this.Http.Abort()
        }

        this.CompleteCancelled()
    }

    ; 响应开始时读取总大小，用于计算百分比
    OnResponseStart(status, contentType, *) {
        if (this.IsDone || this.IsCancelled)
            return

        contentLength := ""
        try contentLength := this.Http.GetResponseHeader("Content-Length")
        if (contentLength != "" && RegExMatch(contentLength, "^\d+$")) {
            this.TotalBytes := contentLength + 0
            this.HasContentLength := this.TotalBytes > 0
        } else {
            this.TotalBytes := 0
            this.HasContentLength := false
        }

        this.ReportProgress()
    }

    ; 每次收到数据块时立即写入临时文件
    OnResponseDataAvailable(data, *) {
        if (this.IsDone || this.IsCancelled)
            return

        byteCount := 0
        dataPtr := this.LockSafeArray(data, &byteCount)
        if (byteCount <= 0 || dataPtr = 0) {
            if (dataPtr != 0)
                this.UnlockSafeArray(data)
            return
        }

        try {
            this.FileObj.RawWrite(dataPtr, byteCount)
        } finally {
            this.UnlockSafeArray(data)
        }

        this.DownloadedBytes += byteCount
        this.ReportProgress()
    }

    ; 下载完成后校验文件并回调完成逻辑
    OnResponseFinished(*) {
        if (this.IsDone)
            return

        if (this.IsCancelled) {
            this.CompleteCancelled()
            return
        }

        finalStatus := 0
        try finalStatus := this.Http.Status
        if (finalStatus != 200) {
            finalStatusText := ""
            try finalStatusText := this.Http.StatusText
            this.Fail("HTTP错误: " finalStatus " - " finalStatusText)
            return
        }

        this.CloseFile()

        if !UpdateDownloader.VerifyDownload(this.TempFile) {
            this.Fail("文件保存失败")
            return
        }

        if (this.HasContentLength && this.TotalBytes > 0)
            this.DownloadedBytes := this.TotalBytes
        else
            this.DownloadedBytes := FileGetSize(this.TempFile)

        this.ReportProgress(true)

        result := {
            success: true,
            tempFile: this.TempFile,
            remoteVersion: this.RemoteVersion
        }

        EventBus.Publish("UpdateDownloadComplete", result)

        if (this.Params.HasProp("onComplete") && (Type(this.Params.onComplete) = "Func" || Type(this.Params.onComplete) = "Closure" || Type(this.Params.onComplete) = "BoundFunc")) {
            callback := this.Params.onComplete
            callback.Call(result)
        }

        this.CleanupHttp()
        this.Result := result
        this.IsDone := true
    }

    ; 下载错误处理
    OnError(errorNumber, errorDescription, *) {
        if (this.IsDone)
            return

        if (this.IsCancelled || UpdateDownloader.IsCancelled) {
            this.CompleteCancelled()
            return
        }

        this.Fail("下载失败: " errorDescription)
    }

    ; 上报下载进度
    ReportProgress(forceComplete := false) {
        if !(this.Params.HasProp("onProgress") && (Type(this.Params.onProgress) = "Func" || Type(this.Params.onProgress) = "Closure" || Type(this.Params.onProgress) = "BoundFunc"))
            return

        if (this.IsDone || this.IsCancelled)
            return

        totalBytes := this.HasContentLength ? this.TotalBytes : 0
        isIndeterminate := !this.HasContentLength
        percent := forceComplete ? 100 : 0

        if (!isIndeterminate && this.TotalBytes > 0)
            percent := Min(100, Max(0, Floor((this.DownloadedBytes * 100) / this.TotalBytes)))

        this.Params.onProgress.Call({
            downloadedBytes: this.DownloadedBytes,
            totalBytes: totalBytes,
            percent: percent,
            isIndeterminate: isIndeterminate
        })
    }

    ; 统一失败处理
    Fail(message) {
        if (this.IsDone)
            return

        this.CloseFile()
        this.DeleteTempFile()
        this.CleanupHttp()

        errorInfo := {
            message: message,
            url: this.DownloadUrl,
            version: this.RemoteVersion
        }

        EventBus.Publish("UpdateDownloadError", errorInfo)

        if (this.Params.HasProp("onError") && (Type(this.Params.onError) = "Func" || Type(this.Params.onError) = "Closure" || Type(this.Params.onError) = "BoundFunc")) {
            callback := this.Params.onError
            callback.Call(errorInfo)
        }

        this.Result := {
            success: false,
            error: message
        }
        this.IsDone := true
    }

    ; 统一取消处理
    CompleteCancelled() {
        if (this.IsDone)
            return

        this.CloseFile()
        this.DeleteTempFile()
        this.CleanupHttp()

        if (this.Params.HasProp("onCancel") && (Type(this.Params.onCancel) = "Func" || Type(this.Params.onCancel) = "Closure" || Type(this.Params.onCancel) = "BoundFunc")) {
            callback := this.Params.onCancel
            callback.Call({message: "用户取消了下载"})
        }

        this.Result := {
            success: false,
            error: "用户取消了下载",
            cancelled: true
        }
        this.IsDone := true
    }

    ; 清理HTTP引用与事件连接
    CleanupHttp() {
        if (this.Http != "") {
            try ComObjConnect(this.Http)
        }
        this.Http := ""
        UpdateDownloader.CurrentHttp := ""
    }

    ; 关闭文件句柄
    CloseFile() {
        if (this.FileObj != "") {
            try this.FileObj.Close()
            this.FileObj := ""
        }
    }

    ; 删除临时文件
    DeleteTempFile() {
        if FileExist(this.TempFile) {
            try FileDelete(this.TempFile)
        }
    }

    ; 锁定 SAFEARRAY 以读取二进制数据
    LockSafeArray(data, &byteCount) {
        byteCount := 0
        safeArray := ComObjValue(data)
        if (safeArray = 0)
            return 0

        lowerBound := 0
        upperBound := -1
        DllCall("oleaut32\SafeArrayGetLBound", "ptr", safeArray, "uint", 1, "int*", &lowerBound)
        DllCall("oleaut32\SafeArrayGetUBound", "ptr", safeArray, "uint", 1, "int*", &upperBound)
        byteCount := upperBound - lowerBound + 1
        if (byteCount <= 0)
            return 0

        dataPtr := 0
        DllCall("oleaut32\SafeArrayAccessData", "ptr", safeArray, "ptr*", &dataPtr)
        return dataPtr
    }

    ; 释放 SAFEARRAY
    UnlockSafeArray(data) {
        safeArray := ComObjValue(data)
        if (safeArray != 0)
            DllCall("oleaut32\SafeArrayUnaccessData", "ptr", safeArray)
    }
}
