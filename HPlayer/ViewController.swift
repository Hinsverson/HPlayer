//
//  ViewController.swift
//  HPlayer
//
//  Created by hinson on 2020/10/4.
//  Copyright © 2020 tommy. All rights reserved.
//

import UIKit
import AVFoundation


class ViewController: UIViewController {
   
    @IBOutlet weak var segment: UISegmentedControl!
    @IBOutlet weak var slider: UISlider!
    lazy var corePlayView: HPPlayerLayer = {
        let v = HPPlayerLayer()
        //v.frame.size = CGSize(width: view.bounds.width, height: view.bounds.width/(CGFloat(840)/CGFloat(360)))
        v.center = view.center //先size，再center
        v.frame = view.bounds
        //v.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        view.insertSubview(v, at: 0)
        return v
    }()
    
    @IBOutlet weak var btnStart: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view.
        btnStart.setTitle("START", for: .normal)
        btnStart.setTitle("PAUSE", for: .selected)
        btnStart.layer.cornerRadius = 4.0
        
        slider.minimumValue = 0
        slider.maximumValue = 1.0
        slider.value = 0.0
        
        let options = HPConfig()
        
        //获取直播流地址
        //https://blog.csdn.net/u014162133/article/details/81188410
        //https://github.com/wbt5/real-url
        //https://juejin.cn/post/6855577308271476743
                
        ///*本地视频
        let url = URL(fileURLWithPath: Bundle.main.path(forResource: "LocalVideoTest", ofType: "mp4")!)
        //let url = URL(string: "http://clips.vorwaerts-gmbh.de/big_buck_bunny.mp4")!
        //*/
    
        /*m3u8
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8")!
        //https://sf1-hscdn-tos.pstatp.com/obj/media-fe/xgplayer_doc_video/hls/xgplayer-demo.m3u8
        */
        
        /*直播
        let url = URL(string: "http://ivi.bupt.edu.cn/hls/cctv5phd.m3u8")!
        */
        
        /*RTMP
        let url = URL(string: "rtmp://58.200.131.2:1935/livetv/sctv")!
        */
        
        /*Https
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/wwdc/2019/244gmopitz5ezs2kkq/244/hls_vod_mvp.m3u8")!
        options.formatContextOptions["timeout"] = 0
        */
        
        /*rtsp
        let url = URL(string: "rtsp://wowzaec2demo.streamlock.net/vod/mp4:BigBuckBunny_115k.mov")!
        options.formatContextOptions["timeout"] = 0
        */
        
        /*flv
        let url = URL(string: "https://sf1-hscdn-tos.pstatp.com/obj/media-fe/xgplayer_doc_video/flv/xgplayer-demo-360p.flv")!
        */
        options.isLoopPlay = true
        //options.isAutoPlay = true
        corePlayView.set(url: url, options: options)
        corePlayView.player?.playbackRate = Float([0.5, 1.0, 2.0][segment.selectedSegmentIndex])
        corePlayView.delegate = self
    }
    
    @IBAction func actionStart(_ sender: Any) {
        !btnStart.isSelected ? corePlayView.play() : corePlayView.pause()
        btnStart.isSelected = !btnStart.isSelected
        
    }
    
    @IBAction func actionSlider(_ sender: Any) {
        let total = corePlayView.player?.duration ?? 0.0
        let seek = total*Double(slider.value)
        corePlayView.seek(time: seek, autoPlay: false) { (success) in
            print(success ? "seek \(seek) success" : "seek \(seek) falied")
        }
    }
    
    @IBAction func actionSegment(_ sender: UISegmentedControl) {
        corePlayView.player?.playbackRate = Float([0.5, 1.0, 2.0][segment.selectedSegmentIndex])
    }
}

extension ViewController: HPPlayerLayerDelegate {
    public func player(layer: HPPlayerLayer, state: HPPlayerState) {
        //print("state: \(state.description)")
    }
    public func player(layer: HPPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        if !slider.isTracking {
            slider.value = Float(currentTime/totalTime)
        }
        HPLog("currentTime: \(currentTime) totalTime: \(totalTime)" )
    }
    
    public func player(layer: HPPlayerLayer, finish error: Error?) {
        HPLog("error: \(String(describing: error?.localizedDescription))" )
    }
    public func player(layer: HPPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        HPLog("bufferedCount: \(bufferedCount) consumeTime: \(consumeTime)" )
    }
}
