# 中文表情名称来源

`zh_names.json` 覆盖本目录 `emoji.json` 的全部 2,013 个条目。

标准名称取自 Unicode CLDR 48 的简体中文表情注释：

- https://github.com/unicode-org/cldr/blob/release-48/common/annotations/zh.xml
- https://github.com/unicode-org/cldr/blob/release-48/common/annotationsDerived/zh.xml

Copyright © 1991-2025 Unicode, Inc. 保留上游许可全文于 [CLDR-LICENSE.txt](CLDR-LICENSE.txt)。

适配说明：按 Unicode 序列匹配，兼容旧 EmojiTwo 数据省略连接符及变体选择符的写法；非标准、历史符号及部分字母缩写由 TideBot 补译或改写为中文。`emoji.json` 与图像原文件保持原样，独立中文名称表由聊天面板加载，用于名称提示、无障碍名称和发送给模型的表情说明。

## 表情分类来源

`categories.json` 记录 TideBot 对 EmojiTwo 分类的调整，依据 [Unicode Emoji 16.0 分类数据](https://www.unicode.org/Public/emoji/16.0/emoji-test.txt)。Copyright © 2024 Unicode, Inc.，适用 [Unicode 许可](CLDR-LICENSE.txt)。旧序列按变体选择符及连接符兼容匹配，未匹配的已收录表情沿用 EmojiTwo 分类。
