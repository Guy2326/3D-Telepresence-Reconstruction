#include "TsdfVolume.h"
#include <pcl/point_cloud.h>
#include <pcl/conversions.h>
#include "Timer.h"

extern "C" void cudaInitVolume(float sizeX, float sizeY, float sizeZ, float centerX, float centerY, float centerZ);
extern "C" void cudaReleaseVolume();
extern "C" void cudaIntegrateDepth(int cameras, UINT16** depth, RGBQUAD** color, Transformation* toWorldTrans, Transformation* depthToColorTrans, Intrinsics* depthIntrinsics, Intrinsics* colorIntrinsics);
extern "C" void cudaCreateMeshAndIntegrateColor(int cameras, Vertex* vertex, int& size);

TsdfVolume::TsdfVolume(float sizeX, float sizeY, float sizeZ, float centerX, float centerY, float centerZ)
{
	cudaInitVolume(sizeX, sizeY, sizeZ, centerX, centerY, centerZ);
}

TsdfVolume::~TsdfVolume()
{
	cudaReleaseVolume();
}

void TsdfVolume::integrate(byte* result, int cameras, UINT16** depth, RGBQUAD** color, Transformation* depthTrans, Transformation* colorTrans, Intrinsics* depthIntrinsics, Intrinsics* colorIntrinsics)
{
	// Input: depthTrans = depth to world transformation, colorTrans = color to depth transformation
	// Output: colorTrans = depthTrans * colorTrans = color to world transformation
	for (int i = 0; i < cameras; i++) {
		colorTrans[i] = depthTrans[i] * colorTrans[i];
	}

	cudaIntegrateDepth(cameras, depth, color, depthTrans, colorTrans, depthIntrinsics, colorIntrinsics);

	Vertex* vertex = (Vertex*)(result + 4);
	cudaCreateMeshAndIntegrateColor(cameras, vertex, *((int*)result));
}

pcl::PointCloud<pcl::PointXYZRGB>::Ptr TsdfVolume::getPointCloudFromMesh(byte* buffer)
{
	int size = *((int*)buffer);
	Vertex* vertex = (Vertex*)(buffer + 4);

	pcl::PointCloud<pcl::PointXYZRGB>::Ptr cloud(new pcl::PointCloud<pcl::PointXYZRGB>());
	cloud->resize(size * 3);

#pragma omp parallel for schedule(static, 500)
	for (int i = 0; i < size * 3; i++) {
		cloud->points[i].x = vertex[i].pos.x;
		cloud->points[i].y = vertex[i].pos.y;
		cloud->points[i].z = vertex[i].pos.z;
		cloud->points[i].r = vertex[i].color.x;
		cloud->points[i].g = vertex[i].color.y;
		cloud->points[i].b = vertex[i].color.z;
	}

	return cloud;
}
