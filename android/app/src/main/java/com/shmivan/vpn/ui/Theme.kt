package com.shmivan.vpn.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

// Fallback palette (pre-Android 12) taken from the app icon's blue→violet gradient.
private val Light = lightColorScheme(
    primary = Color(0xFF4F5BD5), onPrimary = Color.White,
    primaryContainer = Color(0xFFDFE0FF), onPrimaryContainer = Color(0xFF0C1470),
    secondary = Color(0xFF6B3FC0), tertiary = Color(0xFF00897B),
)
private val Dark = darkColorScheme(
    primary = Color(0xFFBCC2FF), onPrimary = Color(0xFF1E2A99),
    primaryContainer = Color(0xFF3641B0), onPrimaryContainer = Color(0xFFDFE0FF),
    secondary = Color(0xFFD3BBFF), tertiary = Color(0xFF80CBC4),
)

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ShmivanTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> Dark
        else -> Light
    }
    MaterialExpressiveTheme(colorScheme = colors, motionScheme = MotionScheme.expressive(), content = content)
}
