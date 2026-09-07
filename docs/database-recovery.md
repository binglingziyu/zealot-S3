# 数据库备份与恢复

S3 模式且已导入存储配置时，后台备份默认只导出 PostgreSQL，不读取/打包应用文件。备份设置可指定独立存储配置；未指定时首次执行绑定当时的系统默认存储。已有归档的备份计划不能直接切换位置，需要新建计划。历史安装包、图标和调试文件继续保存在各自原桶。

备份使用 PostgreSQL custom 格式，临时目录在结束时清理。归档上传后重新读取云端内容校验大小和 SHA256，成功后才写入 `.dump.json` 完成清单。后台列表来自云端清单，不依赖原服务器的本地备份卷。下载通过管理员鉴权后跳转到短期签名 URL。

`max_keeps` 是份数上限（负数不按份数清理），但 `ZEALOT_DATABASE_RETENTION_DAYS` 的恢复窗口优先，默认 30 天。窗口内不能手动删除归档；超过份数但还在窗口内的归档仍保留。业务对象保留期至少为该窗口加 7 天。不能在增加数据库回退窗口后假定此前已删除的对象会重新出现。

## 独立恢复凭据

复制仓库中的 `.env.backup.example` 为受保护的 `.env.backup`，填入原来的 `SECRET_KEY_BASE`、数据库连接，以及可以在数据库尚未恢复时使用的备份桶凭据。不要仅将恢复凭据存放在待恢复数据库内。

备份计划的 prefix 为 `<profile.prefix>/database-backups/<backup.id>`；当 profile prefix 为空时，没有最前面的斜线。CLI 默认使用 `ZEALOT_S3_*`；若备份在独立账户/桶，使用 `ZEALOT_BACKUP_S3_*` 覆盖。该 CLI 使用显式 `ZEALOT_POSTGRES_*`，不接受 `ZEALOT_DATABASE_URL`，避免恢复目标被另一个连接字符串覆盖。

在已装载这些环境变量、使用相同版本镜像的维护容器中执行：

```sh
ruby bin/database_archive list
ruby bin/database_archive backup
```

CLI 可在应用数据库不可用时列出归档；备份操作则需要可用的 PostgreSQL。每条清单包含归档 key、大小和 SHA256，不包含存储密钥。后台备份会登记 StoredObject；独立 CLI 备份只写入云端归档/清单，同样可以恢复。

## 恢复步骤

1. 停止连接目标数据库的 Web 写入及所有 worker，禁止旧容器自动重启。创建目标 PostgreSQL 空库，并使用已知兼容的 `pg_restore`/应用镜像。恢复不是向运行中的数据库热覆盖。
2. 在维护容器装载 `.env.backup`，保持原 `SECRET_KEY_BASE`，设置 `ZEALOT_RECOVERY_MODE=true`。使用清单完整 key 和显式目标库名：

   ```sh
   ruby bin/database_archive restore zealot/database-backups/1/TIMESTAMP-UUID.dump.json zealot_restored
   ```

3. 工具先下载并校验字节数/SHA256，再以单事务 `pg_restore --clean --if-exists` 恢复，运行当前数据库迁移，关闭内部作业和 cron，抑制备份中的旧通知、清理旧 GoodJob 队列及缓存，然后检查当前版本/图标/调试文件的每个对象引用及大小。缺失对象、解密失败或未迁移的文件引用会使命令失败。
4. 保持恢复模式，核对域名、分组权限、备份位置和对象存储配置；验证列表、下载及 iOS manifest。HEAD 大小检查不等于完整对象内容校验；演练另用实际下载/SHA256 验证。
5. 确认通过后，使用恢复后的目标数据库重建服务，移除 `ZEALOT_RECOVERY_MODE`，恢复 worker/cron。上传对账会重新排队中断解析；过期分片按云端状态终止。服务和 frp 公共域名沿用原配置。

恢复模式下，Web/API 中间件统一返回 503，GoodJob 强制外部执行且关闭 cron，ActiveJob（包括邮件及旧版后台任务）在执行前中止。维护命令可以操作数据库；完成核查后重启服务并移除开关才开放访问。该开关不能终止已在另一个旧进程中执行的请求，因此恢复前仍必须停止旧实例。

归档、外部密钥、Compose/frp 配置及保留的对象存储共同构成恢复条件。此流程不覆盖桶/账户整体丢失；不能用数据库恢复替代对象副本。恢复工具不会自动关闭恢复模式或发布服务。

目前演练使用独立 PostgreSQL 数据库和 MinIO。生产 R2、新镜像整体切换、对象删除前备份点回退及完整权限验收仍需完成。
