#include "Kinect2Grabber.h"
#include "Timer.h"
#include <pcl/filters/fast_bilateral_omp.h>

namespace pcl
{
	pcl::Kinect2Grabber::Kinect2Grabber()
		: sensor(nullptr)
		, mapper(nullptr)
		, colorSource(nullptr)
		, colorReader(nullptr)
		, depthSource(nullptr)
		, depthReader(nullptr)
		, result(S_OK)
		, colorWidth(1920)
		, colorHeight(1080)
		, colorBuffer()
		, W(512)
		, H(424)
		, depthBuffer()
		, running(false)
		, quit(false)
		, signal_PointXYZRGB(nullptr)
	{
		// Create Sensor Instance
		result = GetDefaultKinectSensor(&sensor);
		if (FAILED(result)) {
			throw std::exception("Exception : GetDefaultKinectSensor()");
		}

		// Open Sensor
		result = sensor->Open();
		if (FAILED(result)) {
			throw std::exception("Exception : IKinectSensor::Open()");
		}

		// Retrieved Coordinate Mapper
		result = sensor->get_CoordinateMapper(&mapper);
		if (FAILED(result)) {
			throw std::exception("Exception : IKinectSensor::get_CoordinateMapper()");
		}

		// Retrieved Color Frame Source
		result = sensor->get_ColorFrameSource(&colorSource);
		if (FAILED(result)) {
			throw std::exception("Exception : IKinectSensor::get_ColorFrameSource()");
		}

		// Retrieved Depth Frame Source
		result = sensor->get_DepthFrameSource(&depthSource);
		if (FAILED(result)) {
			throw std::exception("Exception : IKinectSensor::get_DepthFrameSource()");
		}

		// Retrieved Color Frame Size
		IFrameDescription* colorDescription;
		result = colorSource->get_FrameDescription(&colorDescription);
		if (FAILED(result)) {
			throw std::exception("Exception : IColorFrameSource::get_FrameDescription()");
		}

		result = colorDescription->get_Width(&colorWidth); // 1920
		if (FAILED(result)) {
			throw std::exception("Exception : IFrameDescription::get_Width()");
		}

		result = colorDescription->get_Height(&colorHeight); // 1080
		if (FAILED(result)) {
			throw std::exception("Exception : IFrameDescription::get_Height()");
		}

		SafeRelease(colorDescription);

		// To Reserve Color Frame Buffer
		colorBuffer.resize(colorWidth * colorHeight);

		// Retrieved Depth Frame Size
		IFrameDescription* depthDescription;
		result = depthSource->get_FrameDescription(&depthDescription);
		if (FAILED(result)) {
			throw std::exception("Exception : IDepthFrameSource::get_FrameDescription()");
		}

		result = depthDescription->get_Width(&W); // 512
		if (FAILED(result)) {
			throw std::exception("Exception : IFrameDescription::get_Width()");
		}

		result = depthDescription->get_Height(&H); // 424
		if (FAILED(result)) {
			throw std::exception("Exception : IFrameDescription::get_Height()");
		}

		SafeRelease(depthDescription);

		// To Reserve Depth Frame Buffer
		depthBuffer.resize(W * H);

		signal_PointXYZRGB = createSignal<signal_Kinect2_PointXYZRGB>();
	}

	pcl::Kinect2Grabber::~Kinect2Grabber() throw()
	{
		stop();

		disconnect_all_slots<signal_Kinect2_PointXYZRGB>();

		thread.join();

		// End Processing
		if (sensor) {
			sensor->Close();
		}
		SafeRelease(sensor);
		SafeRelease(mapper);
		SafeRelease(colorSource);
		SafeRelease(colorReader);
		SafeRelease(depthSource);
		SafeRelease(depthReader);
	}

	void pcl::Kinect2Grabber::start()
	{
		// Open Color Frame Reader
		result = colorSource->OpenReader(&colorReader);
		if (FAILED(result)) {
			throw std::exception("Exception : IColorFrameSource::OpenReader()");
		}

		// Open Depth Frame Reader
		result = depthSource->OpenReader(&depthReader);
		if (FAILED(result)) {
			throw std::exception("Exception : IDepthFrameSource::OpenReader()");
		}

		running = true;

		thread = boost::thread(&Kinect2Grabber::threadFunction, this);
	}

	void pcl::Kinect2Grabber::stop()
	{
		boost::unique_lock<boost::mutex> lock(mutex);

		quit = true;
		running = false;

		lock.unlock();
	}

	bool pcl::Kinect2Grabber::isRunning() const
	{
		boost::unique_lock<boost::mutex> lock(mutex);

		return running;

		lock.unlock();
	}

	std::string pcl::Kinect2Grabber::getName() const
	{
		return std::string("Kinect2Grabber");
	}

	float pcl::Kinect2Grabber::getFramesPerSecond() const
	{
		return 30.0f;
	}

	void pcl::Kinect2Grabber::threadFunction()
	{
		while (!quit) {
			boost::unique_lock<boost::mutex> lock(mutex);

			// Acquire Latest Color Frame
			IColorFrame* colorFrame = nullptr;
			result = colorReader->AcquireLatestFrame(&colorFrame);
			if (SUCCEEDED(result)) {
				// Retrieved Color Data
				result = colorFrame->CopyConvertedFrameDataToArray(colorBuffer.size() * sizeof(RGBQUAD), reinterpret_cast<BYTE*>(&colorBuffer[0]), ColorImageFormat::ColorImageFormat_Bgra);
				if (FAILED(result)) {
					throw std::exception("Exception : IColorFrame::CopyConvertedFrameDataToArray()");
				}
			}
			SafeRelease(colorFrame);

			// Acquire Latest Depth Frame
			IDepthFrame* depthFrame = nullptr;
			result = depthReader->AcquireLatestFrame(&depthFrame);
			if (SUCCEEDED(result)) {
				// Retrieved Depth Data
				result = depthFrame->CopyFrameDataToArray(depthBuffer.size(), &depthBuffer[0]);
				if (FAILED(result)) {
					throw std::exception("Exception : IDepthFrame::CopyFrameDataToArray()");
				}
			}
			SafeRelease(depthFrame);

			lock.unlock();

			if (signal_PointXYZRGB->num_slots() > 0) {
				signal_PointXYZRGB->operator()(convertRGBDepthToPointXYZRGB(&colorBuffer[0], &depthBuffer[0]));
			}
		}
	}

	pcl::PointCloud<pcl::PointXYZRGB>::Ptr pcl::Kinect2Grabber::convertRGBDepthToPointXYZRGB(RGBQUAD* colorBuffer, UINT16* depthBuffer)
	{
		//These two filters for depth image are added by zsyzgu.
		spatialFiltering(depthBuffer);
		temporalFiltering(depthBuffer);

		pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud(new pcl::PointCloud<pcl::PointXYZRGB>());

		cloud->width = static_cast<uint32_t>(W);
		cloud->height = static_cast<uint32_t>(H);
		cloud->is_dense = false;

		cloud->points.resize(H * W);// cloud->height * cloud->width);

		#pragma omp parallel for
		for (int y = 0; y < H; y++) {
			pcl::PointXYZRGB* pt = &cloud->points[y * W];
			for (int x = 0; x < W; x++, pt++) {
				pcl::PointXYZRGB point;

				DepthSpacePoint depthSpacePoint = { static_cast<float>(x), static_cast<float>(y) };
				UINT16 depth = depthBuffer[y * W + x];
				if (depth != 0) {
					// Coordinate Mapping Depth to Color Space, and Setting PointCloud RGB
					ColorSpacePoint colorSpacePoint = { 0.0f, 0.0f };
					mapper->MapDepthPointToColorSpace(depthSpacePoint, depth, &colorSpacePoint);
					int colorX = static_cast<int>(std::floor(colorSpacePoint.X + 0.5f));
					int colorY = static_cast<int>(std::floor(colorSpacePoint.Y + 0.5f));
					if ((0 <= colorX) && (colorX < colorWidth) && (0 <= colorY) && (colorY < colorHeight)) {
						RGBQUAD color = colorBuffer[colorY * colorWidth + colorX];
						point.b = color.rgbBlue;
						point.g = color.rgbGreen;
						point.r = color.rgbRed;
					}

					// Coordinate Mapping Depth to Camera Space, and Setting PointCloud XYZ
					CameraSpacePoint cameraSpacePoint = { 0.0f, 0.0f, 0.0f };
					mapper->MapDepthPointToCameraSpace(depthSpacePoint, depth, &cameraSpacePoint);
					if ((0 <= colorX) && (colorX < colorWidth) && (0 <= colorY) && (colorY < colorHeight)) {
						point.x = cameraSpacePoint.X;
						point.y = cameraSpacePoint.Y;
						point.z = cameraSpacePoint.Z;
					}
					*pt = point;
				}
			}
		}

		//The BilateralFileter is added by zsyzgu.
		/*pcl::FastBilateralFilterOMP<pcl::PointXYZRGB> bFilter;
		bFilter.setNumberOfThreads(8);
		bFilter.setInputCloud(cloud);
		bFilter.filter(*cloud);*/

		int j = 0;
		for (int i = 0; i < cloud->size(); i++) {
			if (depthBuffer[i] != 0) {
				cloud->points[j++] = cloud->points[i];
			}
		}
		cloud->resize(j);

		return cloud;
	}

	void pcl::Kinect2Grabber::spatialFiltering(UINT16* depth) {
		// 170 us
		static const int n = 512 * 424;
		static UINT16 rawDepth[n];

		memcpy(rawDepth, depth, n * sizeof(UINT16));

		#pragma omp parallel for
		for (int y = 0; y < H; y++) {
			for (int x = 0; x < W; x++) {
				int index = y * W + x;
				if (rawDepth[index] == 0) {
					int num = 0;
					int sum = 0;
					for (int dx = -2; dx <= 2; dx++) {
						for (int dy = -2; dy <= 2; dy++) {
							if (dx != 0 || dy != 0) {
								int xSearch = x + dx;
								int ySearch = y + dy;

								if (0 <= xSearch && xSearch < W && 0 <= ySearch && ySearch < H) {
									int searchIndex = ySearch * W + xSearch;
									if (rawDepth[searchIndex] != 0) {
										num++;
										sum += rawDepth[searchIndex];
									}
								}
							}
						}
					}
					if (num != 0) {
						depth[index] = sum / num;
					}
				}
			}
		}
	}

	void pcl::Kinect2Grabber::temporalFiltering(UINT16* depthData) {
		// 360 us

		// Abstract: The system error of a pixel from the depth image is nearly white noise. We use several frames to smooth it.
		// Implementation: If a pixel not change a lot in this frame, we would smooth it by averaging the pixels in several frames.

		static const int QUEUE_LENGTH = 5;
		static const int THRESHOLD = 10;
		static const int n = 512 * 424;
		static UINT16 depthQueue[QUEUE_LENGTH][n];
		static int t = 0;

		memcpy(depthQueue[t], depthData, n * sizeof(UINT16));

		#pragma omp parallel for
		for (int y = 0; y < H; y++) {
			for (int x = 0; x < W; x++) {
				int index = y * W + x;
				int sum = 0;
				int num = 0;
				for (int i = 0; i < QUEUE_LENGTH; i++) {
					if (depthQueue[i][index] != 0) {
						sum += depthQueue[i][index];
						num++;
					}
				}
				if (num == 0) {
					depthData[index] = 0;
				}
				else {
					depthData[index] = (UINT16)(sum / num);
					if (abs(depthQueue[t][index] - depthData[index]) > THRESHOLD) {
						depthData[index] = depthQueue[t][index];
						for (int i = 0; i < QUEUE_LENGTH; i++) {
							depthQueue[t][index] = 0;
						}
					}
				}
			}
		}

		t = (t + 1) % QUEUE_LENGTH;
	}
}

/*
Another implementation of spatialFiltering()

// Abstract: Depth image captured by Kinect2 is usually missing some pixels. We use their neighbor pixels to estimate them.
// Implemention [9 * O(n)]: Constantly find the unkonwn pixel with the most known neighbours, and assign it by averaging its neighbours.

static const int n = 512 * 424;
static int pixelQueue[9][n];
int tot[9] = {0};
int cnt[9] = {0};
byte* uncertainty = new byte[n];

for (int y = 0; y < H; y++) {
for (int x = 0; x < W; x++) {
int index = y * W + x;
if (depthData[index] == 0) {
int lv = 0;
for (int dx = -1; dx <= 1; dx++) {
for (int dy = -1; dy <= 1; dy++) {
if (dx != 0 || dy != 0) {
int xSearch = x + dx;
int ySearch = y + dy;

if (0 <= xSearch && xSearch < W && 0 <= ySearch && ySearch < H) {
int searchIndex = ySearch * W + xSearch;
if (depthData[searchIndex] == 0) {
lv++;
}
} else {
lv++;
}
}
}
}
uncertainty[index] = lv;
pixelQueue[lv][tot[lv]++] = index;
}
}
}

for (int lv = 0; lv < 9; ) {
if (cnt[lv] >= tot[lv]) {
lv++;
continue;
}

int index = pixelQueue[lv][cnt[lv]++];
if (uncertainty[index] != lv) {
continue;
}

int y = index / W;
int x = index % W;
int sum = 0;
int num = 0;
for (int dx = -1; dx <= 1; dx++) {
for (int dy = -1; dy <= 1; dy++) {
if (dx != 0 || dy != 0) {
int xSearch = x + dx;
int ySearch = y + dy;

if (0 <= xSearch && xSearch < W && 0 <= ySearch && ySearch < H) {
int searchIndex = ySearch * W + xSearch;
if (depthData[searchIndex] == 0) {
int searchLv = --uncertainty[searchIndex];
pixelQueue[searchLv][tot[searchLv]++] = searchIndex;
} else {
sum += depthData[searchIndex];
num++;
}
}
}
}
}

if (num == 0) {
return; //All pixels are zero
} else {
depthData[index] = (UINT16)(sum / num);
}

if (lv - 1 >= 0 && cnt[lv - 1] < tot[lv - 1]) {
lv--;
}
}

delete[] uncertainty;*/