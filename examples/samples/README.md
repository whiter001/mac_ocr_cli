# Samples

这个目录是占位 —— 你可以放自己想测试的图片,或者把识别结果跑出 demo 数据。

## 建议样本

- **screenshot.png** —— 一张普通的应用截图(英文 UI),用来测 `mac_ocr_cli screenshot.png`
- **receipt.jpg** —— 一张收据照片,测试 `--keyword "金额"`
- **cjk.png** —— 一张含中文的截图,测试默认语言(`--lang zh-Hans,zh-Hant,en-US`)
- **batch/** —— 一个装 5-10 张截图的目录,测 `--dir` + `--compress-output`

## 怎么用

```bash
# 单文件 OCR
../01-basic/single_text.sh ./screenshot.png

# 批量
../02-batch/dir_scan.sh ./batch/ ./batch_result.json

# 压缩归档
../04-compression/archive_to_webp.sh ./batch/ ./batch_webp/
```

## 注意事项

- 真实场景里 OCR 识别率高度依赖图片质量(分辨率、光照、字体清晰度)。
- 同一张图换不同 `--level`(`accurate` vs `fast`)或 `--lang` 可能有不同结果。
- 想跑 `--screen` / `--clipboard` 类 demo,去看 `../03-capture/`。