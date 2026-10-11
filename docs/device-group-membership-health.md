# 机构设备组成员关联状态

## 目的与边界

机构管理员需要在最多 5000 台设备的组内识别旧注册周期、未激活设备和已归档档案，再清理成员。此处的“关联有效”只表示设备身份当前可作为一次性组策略目标；**不是应用限制生效、系统管控或设备合规率**。

## 接口

`GET /api/v1/tenants/{tenantId}/device-groups/{groupId}/summary` 仅机构 OWNER/ORG_ADMIN 可读，返回 `groupId,version,total,current,staleRegistration,deviceInactive,profileArchived` 和版本 `ETag`。四种状态互斥，合计必须等于 `total`；服务端与客户端均拒绝不一致的结果。后端在同一个只读事务中读取当前组版本及全部成员计数，空组返回五个零。该汇总查询不读取儿童使用行为或设备密钥。

`GET .../{groupId}/devices?status=CURRENT|STALE_REGISTRATION|DEVICE_INACTIVE|PROFILE_ARCHIVED` 按指定状态及设备 ID 分页；缺省状态返回全部成员。未知状态返回 `INVALID_DEVICE_GROUP_STATUS`。分类先看档案是否归档，再看注册周期、设备活动状态，与成员详情中的 `membershipStatus` 一致。组归档后仍可读取历史统计与成员，但不能编辑。

管理端用标明分母的进度条和状态筛选展示全组数量；筛选后成员清单由服务端分页，不用当前已加载页面推断全组统计。旧注册、停用及归档档案成员可通过批量移出清理。界面要求组详情版本、成员汇总版本和总数一致；变化时要求刷新。设备活动状态可能在不改变组版本的情况下变化，统计与分页列表都是读取时快照，刷新后再决定操作。移出不撤销设备注册或已发布配置。

## 发布前核对

需要真实 MySQL/OceanBase 核对空组、5000 台上限、四状态分区、跨租户拒绝、归档组只读、并发成员变化与分页；还需窄屏、键盘和机构账号的实际界面检查。静态分析和构建不能替代这些运行证据。
