float signal_pal(int mode, float fps, float debug_pal)
{
    if (mode < 0)
        return timing_profile_pal(mode, 0.0);
    if (debug_pal > 0.5)
        return 1.0;
    return timing_profile_pal(mode, fps <= 55.0 ? 1.0 : 0.0);
}
