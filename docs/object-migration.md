# 历史对象跨存储迁移

迁移只由有效的平台管理员发起。`source_object_id` 来自版本的 `package_object_id`、`icon_object_id` 或调试文件的 `stored_object_id`。目标是已有且启用的 StorageProfile。备份归档不走这个迁移入口。

```sh
# 创建持久任务并入队；重复请求复用同一来源/目标的任务
ruby bin/object_migration start ADMIN_ID SOURCE_OBJECT_ID TARGET_PROFILE_ID
# 查询状态，或在维护 worker 中同步执行/重试
ruby bin/object_migration status ADMIN_ID MIGRATION_UUID
ruby bin/object_migration run ADMIN_ID MIGRATION_UUID
# 取消未完成任务，目标临时对象进入保留清理期
ruby bin/object_migration cancel ADMIN_ID MIGRATION_UUID
```

自动任务在 `storage_migration` 队列；独立 worker 可以只消费此队列。迁移发起人的管理权限会在执行和切换阶段重新检查。恢复模式禁止迁移。停滞的 pending/copying 任务由上传对账重新排队；failed 任务按上述命令显式重试。

任务下载源对象并核对 SHA256，复制到目标独立 UUID key，再完整读取目标校验大小和 SHA256。已有正确的目标副本可以复用。只有校验成功后，才在一个数据库事务内切换包、图标或调试文件引用，标记任务完成，并开始源对象的完整保留窗口。复制失败、验证失败、切换事务失败或取消都不改变原引用。

迁移不修改应用/分组的默认存储绑定。已有上传会话保留原始上传对象位置；成功结果通过对应 release/debug_file 读取迁移后的引用。原对象保留至少 `max(对象保留天数, 数据库保留天数 + 7)`，供旧数据库备份恢复使用。长期失败且目标已被清理的任务应取消后重新创建；源文件仍按原引用使用。

迁移使用受限的本地流式下载和临时文件，默认受 `ZEALOT_PARSER_MAX_FILE_BYTES` 的 20 GiB 限制。跨厂商会通过 worker 中转，并不依赖跨厂商 CopyObject。生产 R2/其他提供商仍需最终协议验收。
