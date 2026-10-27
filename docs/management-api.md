# 分组与存储管理 API

所有接口使用 `Authorization: Bearer <用户 token>`。CI 可使用仅获目标应用权限的专用用户。`channel_key` 不是身份凭据。以下接口与网页管理采用同一权限规则。

| 接口 | 权限及用途 |
| --- | --- |
| `GET /api/groups` | 仅列出当前用户可见分组 |
| `POST /api/groups` | 平台管理员创建分组 |
| `GET /api/groups/:id` | 查看分组；`app_ids` 仅含当前用户可见应用 |
| `PATCH /api/groups/:id` | 平台或该分组管理员更新名称、描述、默认存储 |
| `DELETE /api/groups/:id` | 同上；分组内有应用时返回 422 |
| `GET /api/groups/:id/members` | 分组管理员查看成员 |
| `POST /api/groups/:id/add_member` | 以 `email` 和 `role` 设置成员；角色为 `viewer`、`developer`、`admin` |
| `DELETE /api/groups/:id/members/:membership_id` | 移除该分组授权；应用直接授权独立保留 |
| `GET /api/groups/:id/available_storage` | 分组管理员查询可选择的存储，仅返回 ID、名称和默认标记 |
| `GET /api/apps/:id/available_storage` | 应用管理员查询可选择的存储，同样不返回连接地址或凭据 |
| `GET/POST /api/storage_profiles` | 仅平台管理员列出或创建存储配置 |
| `GET/PATCH/DELETE /api/storage_profiles/:id` | 仅平台管理员查看、更新或删除；仍被引用时禁止删除 |
| `POST /api/storage_profiles/:id/check` | 检查 Bucket 可访问性；不代表已验证上传或删除权限 |

分组创建和更新使用嵌套对象：

```json
{
  "group": {
    "name": "基础设施",
    "description": "内部应用",
    "storage_profile_id": 1
  }
}
```

存储创建和更新使用 `storage_profile` 对象。可写字段为 `name`、`provider`、`region`、`bucket`、`endpoint`、`download_endpoint`、`prefix`、`force_path_style`、`enabled`、`system_default`、`url_expires_in`。凭据字段是 `access_key_id`、`secret_access_key`、可选的 `session_token`；设置或轮换时同时提供 access key 和 secret。响应永远不包含明文密钥或加密密文，只提供 `credentials_version`。

```json
{
  "storage_profile": {
    "name": "R2 infrastructure",
    "provider": "r2",
    "region": "auto",
    "endpoint": "https://ACCOUNT_ID.r2.cloudflarestorage.com",
    "bucket": "infrastructure",
    "prefix": "zealot",
    "force_path_style": true,
    "enabled": true,
    "access_key_id": "REPLACE_WITH_ACCESS_KEY",
    "secret_access_key": "REPLACE_WITH_SECRET_KEY",
    "group_ids": [1],
    "app_ids": []
  }
}
```

将实际凭据放在权限为 0600 的临时 JSON 文件中，通过 `curl --data-binary @文件` 提交，避免把密钥写入命令历史。省略凭据或全部留空会保留现有凭据。没有显式凭据时使用 AWS SDK 的运行环境凭据链。

`group_ids`、`app_ids` 为可选的授权数组：省略表示保持现状，空数组表示清空对应授权。授权允许管理员选择该存储，不授予读取其他应用的权限。默认切换、凭据轮换和授权替换在同一数据库事务内完成；未知授权 ID 导致整体回滚。

应用 API 保持原有的顶层参数格式，例如：

```json
{
  "group_id": 1,
  "storage_profile_id": 2,
  "inherit_group_permissions": true
}
```

提交至 `PATCH /api/apps/:id`。应用存储优先于分组存储，随后回退到系统默认。修改绑定只影响新上传，历史对象继续使用记录的原存储位置。已被对象引用的 Endpoint、Bucket、prefix 等位置字段不可修改，应创建新配置再切换绑定。停用存储阻止新上传，不删除历史文件。

常见状态码：201 创建成功，200 查询或更新成功，204 删除成功，403 权限不足，404 资源不存在或不在可见范围，422 参数无效或仍被引用。
