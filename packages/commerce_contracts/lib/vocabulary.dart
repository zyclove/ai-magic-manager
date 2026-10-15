const catalogChannels = [
  'GOOGLE_PLAY',
  'APP_STORE',
  'CONTRACT',
  'PRIVATE_LICENSE'
];
const catalogBuyerKinds = ['FAMILY', 'ORGANIZATION'];
const catalogPlatforms = ['ANDROID', 'ANDROID_TV', 'IOS', 'WINDOWS', 'MACOS'];
const catalogDeviceModes = [
  'BYOD',
  'WORK_PROFILE',
  'FULLY_MANAGED',
  'DEDICATED'
];
const catalogBillingPeriods = ['MONTH', 'YEAR', 'ONE_TIME'];
const catalogPriceTypes = ['FIXED', 'QUOTE'];
const catalogTaxBases = ['INCLUSIVE', 'EXCLUSIVE', 'QUOTE_REQUIRED'];
const catalogCapacityKinds = ['BASE', 'ADD_ON'];
const catalogFeatures = [
  'ADVANCED_SCHEDULES',
  'WEB_FILTERING',
  'MANAGED_ANDROID',
  'ORG_BULK',
  'AI_INSIGHTS'
];
const catalogStates = ['DRAFT', 'IN_REVIEW', 'APPROVED', 'RETIRED'];

/// Shared sales vocabulary for catalog editing and contract comparison.
String catalogLabel(String code) =>
    const {
      'DRAFT': '草稿',
      'IN_REVIEW': '待审核',
      'APPROVED': '已审核',
      'RETIRED': '已下架',
      'MISSING': '报价不可用',
      'CREATED': '创建',
      'REVISED': '修订',
      'SUBMITTED': '提交审核',
      'GOOGLE_PLAY': 'Google Play',
      'APP_STORE': 'App Store',
      'CONTRACT': '合同',
      'PRIVATE_LICENSE': '私有许可',
      'FAMILY': '家庭',
      'ORGANIZATION': '机构',
      'ANDROID': 'Android 手机/平板',
      'ANDROID_TV': 'Android TV',
      'IOS': 'iOS',
      'WINDOWS': 'Windows',
      'MACOS': 'macOS',
      'BYOD': '家庭自有设备',
      'WORK_PROFILE': '工作资料模式',
      'FULLY_MANAGED': '完全受管设备',
      'DEDICATED': '专用设备',
      'MONTH': '月付',
      'YEAR': '年付',
      'ONE_TIME': '一次性',
      'FIXED': '固定价',
      'QUOTE': '人工报价',
      'INCLUSIVE': '含税',
      'EXCLUSIVE': '未税',
      'QUOTE_REQUIRED': '报价时确认',
      'BASE': '基础名额',
      'ADD_ON': '加购名额',
      'ADVANCED_SCHEDULES': '精细时间计划',
      'WEB_FILTERING': '网站分类管理',
      'MANAGED_ANDROID': '受管 Android 功能权益',
      'ORG_BULK': '机构批量管理',
      'AI_INSIGHTS': '智能使用建议'
    }[code] ??
    code;
