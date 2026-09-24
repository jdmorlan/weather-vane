//
//  RadarKernelExport.swift  (WeatherKit)
//
//  The Level II decoder and renderer live in `RadarKernel` so they can be
//  compiled optimised in Debug (see Package.swift). Re-exported here so the apps
//  keep importing WeatherKit alone and never need to know the split exists.
//

@_exported import RadarKernel
