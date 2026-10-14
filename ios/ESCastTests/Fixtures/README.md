此資料夾供原生 iOS 解碼測試使用。`tools/run_hls_native_tests.sh` 會先產生自製的 12 秒影音素材，再將 `hls-native-source.mp4` 複製到這裡，供測試 bundle 讀取。

素材為 854×480、60 fps、暗底加每兩秒一次白色方塊與音訊脈衝，不含手機錄影或私人資料。生成的 MP4 不納入 Git。
