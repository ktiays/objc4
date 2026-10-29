#pragma once
// Android has no Apple feature-flag service. Keep each caller's explicit default.
#define os_feature_enabled_simple(domain, feature, defaultValue) (defaultValue)
