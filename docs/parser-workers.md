# 独立解析进程

直传的 `ProcessUploadJob` 启动全新的 Ruby 子进程进行下载、校验、解析和发布，不在 Web/GoodJob 的 Ruby 进程内解析包。每次任务都使用专属临时目录，包含下载文件、AppInfo 解压目录和 CarrierWave 图标缓存。子进程不启动其他 GoodJob worker 或定时任务。

| 环境变量 | 默认值 | 作用 |
|---|---:|---|
| `ZEALOT_PARSER_CONCURRENCY` | 2 | PostgreSQL advisory lock 限制的并发解析槽位；所有连接同一数据库的 worker 应使用一致配置 |
| `ZEALOT_PARSER_TIMEOUT_SECONDS` | 600 | 包含 Rails 启动的总运行时间；超时终止整个进程组 |
| `ZEALOT_PARSER_CPU_SECONDS` | 300 | 操作系统限制单进程 CPU 时间 |
| `ZEALOT_PARSER_MEMORY_BYTES` | 4294967296 | 操作系统限制子进程虚拟地址空间，默认 4 GiB，并非常驻内存预分配 |
| `ZEALOT_PARSER_MAX_FILE_BYTES` | 21474836480 | 下载和单文件写入上限，默认 20 GiB |
| `ZEALOT_PARSER_EXPANDED_BYTES` | 34359738368 | ZIP 中声明的展开总大小上限，默认 32 GiB |
| `ZEALOT_PARSER_SCRATCH_BYTES` | 68719476736 | 单任务临时目录总文件大小监测阈值，默认 64 GiB |
| `ZEALOT_PARSER_SCRATCH_ENTRIES` | 100000 | ZIP 条目数量及临时目录条目数量上限 |

配置值必须为正整数。内存、CPU 和单文件写入采用 Linux 资源限制；总临时空间和条目数每 250 ms 扫描一次，可能在终止前短暂超过阈值，不等同文件系统硬配额。部署时仍须为容器分配足够的总内存/磁盘，并按服务器容量调低并发；两个任务的临时空间和内存会叠加。

解析前检查 ZIP 路径，拒绝绝对路径、上级目录及符号链接，并检查条目数和展开大小。固定版本 RubyZip 默认启用实际展开大小校验。非 ZIP 格式仍受进程时间、内存、文件和临时目录限制。这里是解析资源隔离，不是针对任意代码执行的安全沙箱；子进程仍需要访问数据库和绑定的对象存储。

超时或非正常退出时，只有仍属于本次尝试的会话会转为 `failed`，保留 S3 对象供重试。后续尝试及已成功发布的结果不会被旧进程的失败覆盖。同一会话的解析仍由数据库锁串行化。父进程消失时，子进程的看守线程终止进程组；正常退出/异常退出都清理临时目录。主进程崩溃遗留的目录由上传对账任务清理：超过两小时且没有父/子进程持有文件锁才可删除。

## 单独运行解析 worker

默认继续在应用中运行 GoodJob 调度，由它启动隔离解析子进程。要将解析移到另一台机器，可在 Web 进程使用 `ZEALOT_JOB_QUEUES=-app_parse`，让它保留其他后台任务；独立 worker 使用同一数据库、外部 `SECRET_KEY_BASE`、对象存储访问配置和相同版本镜像。公共 `ZEALOT_DOMAIN` 保持一致。

在独立 worker 中执行：

```sh
ZEALOT_JOB_EXECUTION_MODE=external ZEALOT_ENABLE_CRON=false \
  bundle exec good_job start --queues=app_parse --max-threads=2 --no-enable-cron
```

若 Web 完全不执行后台任务，设置 `ZEALOT_JOB_EXECUTION_MODE=external`，同时另行运行覆盖其余队列的 GoodJob worker，并确保定时任务仍有执行节点。`ZEALOT_JOB_QUEUES` 只选择当前 GoodJob 进程消费的队列，不修改作业的队列归属。

本实现覆盖直传会话的解析。旧版独立 `TeardownJob`/`DebugFileTeardownJob` 入口的执行方式及完整生产资源配置仍需在最终部署审计中核对。修改配置或升级后要重新构建镜像并重启进程；长驻的旧测试服务器不会自动加载这些改动。
