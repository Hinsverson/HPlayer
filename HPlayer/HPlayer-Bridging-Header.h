//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import "libavfilter/avfilter.h"
#import "libavfilter/buffersrc.h"

#import "libavutil/avutil.h"
#import "libavutil/display.h"

#import "libavdevice/avdevice.h"

#import "libavformat/avformat.h"

#import "libswscale/swscale.h"

#import "libavcodec/avcodec.h"

#import "libswresample/swresample.h"

///* 头文件import
#include <stdbool.h>
#include "libavutil/error.h"
#include "libavutil/samplefmt.h"
#include "libavcodec/avcodec.h"
#include "libavutil/pixdesc.h"
#include "libavutil/common.h"
#include "libavutil/dict.h"
#include "libavutil/time.h"
#include "libavutil/display.h"
#include "libavutil/imgutils.h"
// #include "libavdevice/avdevice.h"
// #include "libavfilter/avfilter.h"
#include "libavformat/avformat.h"
#include "libavutil/avutil.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"

//Swift无法处理C中的宏，所以在这里桥接
static __inline__ int AVERROR_CONVERT(int err) {
    return AVERROR(err);
}

static __inline__ bool IS_AVERROR_EOF(int err) {
    return err == AVERROR_EOF;
}

static __inline__ bool IS_AVERROR_INVALIDDATA(int err) {
    return err == AVERROR_INVALIDDATA;
}


static __inline__ bool AVFILTER_EOF(int ret) {
    return ret == AVERROR(EAGAIN) || IS_AVERROR_EOF(ret);
}

/*EAGAIN类的错误，一般是当前状态下无法输出，比如send/receive时, received第一帧时就可能需要额外send其他帧后，才能接受到正确的frame
 output is not available in this state - user must try to send new input
 */
static __inline__ bool IS_AVERROR_EAGAIN(int ret) {
    return ret == AVERROR(EAGAIN);
}
//*/
