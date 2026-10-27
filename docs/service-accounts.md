# Fastlane / SDK 专用服务账号

服务账号使用现有 API Bearer token，但只能读取或上传指定应用，不能网页登录、管理应用或存储，也不继承分组成员权限。创建时使用不可交互的随机密码和已确认的内部占位邮箱，不发送邀请邮件。请分别为 CI 上传和 SDK 读取创建不同账号。

在应用维护容器执行：

```sh
ruby bin/service_account create ADMIN_ID fastlane-ci upload APP_ID
ruby bin/service_account create ADMIN_ID sdk-reader read APP_ID
# 重设授权范围（替换已有授权）
ruby bin/service_account grant ADMIN_ID ACCOUNT_ID read APP_ID_1 APP_ID_2
ruby bin/service_account rotate ADMIN_ID ACCOUNT_ID
ruby bin/service_account revoke ADMIN_ID ACCOUNT_ID
```

创建/轮换仅在命令输出中返回新 token；请存入 CI secret 或相应客户端配置，避免公开日志。授权变更、轮换和撤销有不含 token 的审计记录。撤销锁定账号并使旧 token 失效；在途上传发布也会重新检查账号状态。轮换/锁定账号时同步失效相关应用的安装清单 ticket。已发出的 S3 URL 仍可能在短期有效期内使用。

Fastlane 的 `zealot_direct_upload` action 使用这个 token 作为现有 `token:` 参数，其他直传配置见 `clients/fastlane/README.md`。

SDK 读取使用应用对应的 read 账号，在请求中添加：

```http
GET /api/apps/latest?channel_key=CHANNEL_KEY
Authorization: Bearer SERVICE_ACCOUNT_TOKEN
```

`channel_key` 只定位渠道，不是授权凭据。已有 SDK 若不能设置请求头，需要在其 HTTP 层增加 Authorization，或使用支持该请求头的调用封装；服务端仍兼容 `token` 参数，但不建议把 token 放进 URL。此处没有改写或发布第三方 SDK 包。
