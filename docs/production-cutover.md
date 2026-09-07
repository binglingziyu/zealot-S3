# 生产切换与回滚

状态：候选镜像已验证，尚未正式切换。用户明确要求保留 `infra.s3.mockdata.work` 启用状态；它曾短暂被停用，已立即恢复并确认显示“已启用”。不得再次停用或删除该域名。正在确认域名用于公开下载还是授权下载，再决定保护方案；不要向公开可读的对象位置写数据库备份。

## 已准备的材料

- 部署目录：`/Users/hubin/docker-zealot`，主机 `hubin@192.168.31.230`。
- 现有入口：https://zealot.dev.ihubin.com ，沿用现有 frp/反代配置。证书修复按用户要求暂缓。
- 候选镜像：`zealot-s3:next-70689cb9`，amd64，ID `sha256:c5697ca7c3676d64765695dc34eaeec8b499d4f4db57e4117b7e6b9c91c1a1aa`。
- 旧镜像：`zealot-s3:6.2.2-ec729d2d`。
- 合并配置：将 `deploy/compose.production-next.yaml` 复制为部署目录中的 `compose.next.yaml`，同时复制 `deploy/production-limits.env`。覆盖只设置镜像与解析资源，不重建 PostgreSQL，不更改入口。
- 已演练的回滚备份：`backups/pre-direct-upload-20260907-9b073ab2/`。正式切换前还需停止写入后生成最新归档，不能使用演练归档覆盖此后新增的数据。
- 最终镜像已在生产副本验证当前 schema 00006、幂等导入、原应用/账号保留、加密凭据解密和 Zeitwerk。业务包已在前一候选镜像完成真实 R2 APK/IPA/dSYM 流程；后续权限修复另有针对性检查。

## 切换顺序

落实与用户选择一致的下载授权及备份保护方案后，在部署目录执行。先检查镜像 ID 与候选值一致，再验证合并配置：

```sh
docker image inspect zealot-s3:next-70689cb9 --format '{{.Id}}'
docker compose -f compose.yaml -f compose.next.yaml config --quiet
```

停止 Zealot Web/内置 worker，保留 PostgreSQL；确认没有其他外部 worker 连接生产库。生成权限受限的新数据库归档并复制当前 `.env`、`.env.s3`、Compose 和反代配置。`SECRET_KEY_BASE` 必须保留在独立恢复来源。

```sh
docker compose stop zealot
umask 077
cutover_backup="backups/pre-cutover-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$cutover_backup"
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-acl' > "$cutover_backup/database.dump"
# pg_dump 必须成功后再继续；校验归档能被 pg_restore --list 读取。
cp .env .env.s3 compose.yaml Caddyfile "$cutover_backup/"
```

以恢复模式执行迁移与旧存储导入，不执行定时清理或通知：

```sh
docker compose -f compose.yaml -f compose.next.yaml run --rm --no-deps \
  -e ZEALOT_RECOVERY_MODE=true -e ZEALOT_JOB_EXECUTION_MODE=external -e ZEALOT_ENABLE_CRON=false \
  --entrypoint /bin/sh zealot -c \
  'bundle exec rails db:migrate && bundle exec rails runner "Storage::Bootstrap.call; puts Recovery::DatabaseVerifier.call.to_json"'
```

成功后启动候选镜像，核对健康状态、管理员/普通成员权限、已有应用、网页和 Fastlane 直传、下载签名及后台任务。仅使用明确的验收样例创建/清理测试版本；保留其他用户数据。正式验收后更新部署 README 的实际镜像、存储位置和账号使用说明。

```sh
docker compose -f compose.yaml -f compose.next.yaml up -d --no-deps zealot
docker compose -f compose.yaml -f compose.next.yaml ps
```

旧中转上传接口在切换期保留；以新版本正式验收日为起点安排 30 天迁移窗口，在 README 记录明确退役日期，CI 迁移到 `zealot_direct_upload` 后再关闭旧入口。旧插件不会自动获得直传能力。独立解包和旧中转解析不能宣称具有直传隔离进程的全部资源限制。

## 回滚边界

在尚未开放业务写入、验收失败的情况下，停止候选 Web/worker，用刚生成的切换前归档恢复原 PostgreSQL（单事务 `pg_restore --clean --if-exists --no-owner --no-acl --exit-on-error`），还原原配置并以原 `compose.yaml` 启动旧镜像。切勿仅降级镜像：新版本对象映射/文件路径与旧镜像并不完全兼容。

若已产生实际业务写入，回滚旧数据库会丢失新写入，必须先制定保留这些数据的回退方案，不能自动覆盖。数据库旧备份恢复要求的对象保留窗口已通过测试；对象云账户/桶整体丢失不在 DB-only 恢复保证内。完整恢复命令见 `database-recovery.md`。
