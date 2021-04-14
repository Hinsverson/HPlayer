//
//  AppDelegate.swift
//  HPlayer
//
//  Created by hinson on 2020/10/4.
//  Copyright © 2020 tommy. All rights reserved.
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {


    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        //初始化libavformat并注册所有muxers，demuxers与协议。如果不调用此功能，则可以选择一个特定想要支持的格式。
        //av_register_all()
        
        return true
    }

}

