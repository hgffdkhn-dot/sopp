package com.sopp.su.ui

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.ListView
import android.widget.TextView
import android.widget.Toolbar
import com.sopp.su.R
import com.sopp.su.bridge.HotStart
import com.sopp.su.bridge.NativeBridge
import com.sopp.su.bridge.RootDetector
import com.sopp.su.data.FeatureFlags
import com.sopp.su.data.PackageScanner
import java.util.concurrent.Executors

/** Main screen: kernel status, hot start, per-app authorisation, modules. */
class MainActivity : Activity() {

    private lateinit var pageHome: View
    private lateinit var pageSuperuser: View
    private lateinit var pageModules: View
    private lateinit var statusValue: TextView
    private lateinit var statusIcon: ImageView
    private lateinit var featureProfile: TextView
    private lateinit var featureDenylist: TextView
    private lateinit var featureSepolicy: TextView
    private lateinit var featureSafemode: TextView
    private lateinit var rootState: TextView
    private lateinit var hotStartButton: Button
    private lateinit var hotStartResult: TextView
    private lateinit var superuserList: ListView
    private lateinit var emptyHint: TextView
    private lateinit var moduleState: TextView
    private lateinit var adapter: AppListAdapter

    private val executor = Executors.newFixedThreadPool(2)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val toolbar = findViewById<Toolbar>(R.id.toolbar)
        toolbar.setTitle(R.string.app_name)
        setActionBar(toolbar)

        pageHome = findViewById(R.id.page_home)
        pageSuperuser = findViewById(R.id.page_superuser)
        pageModules = findViewById(R.id.page_modules)
        statusValue = findViewById(R.id.status_value)
        statusIcon = findViewById(R.id.status_icon)
        featureProfile = findViewById(R.id.feature_profile)
        featureDenylist = findViewById(R.id.feature_denylist)
        featureSepolicy = findViewById(R.id.feature_sepolicy)
        featureSafemode = findViewById(R.id.feature_safemode)
        rootState = findViewById(R.id.root_state)
        hotStartButton = findViewById(R.id.hotstart_button)
        hotStartResult = findViewById(R.id.hotstart_result)
        superuserList = findViewById(R.id.superuser_list)
        emptyHint = findViewById(R.id.empty_hint)
        moduleState = findViewById(R.id.module_state)

        adapter = AppListAdapter(this)
        superuserList.adapter = adapter

        listOf(R.id.nav_home, R.id.nav_superuser, R.id.nav_modules)
            .forEachIndexed { index, id ->
                findViewById<View>(id).setOnClickListener { showPage(index) }
            }

        hotStartButton.setOnClickListener { onHotStartClicked() }

        renderStatus()
        loadSuperuserList()
        checkRootInBackground()
    }

    override fun onResume() {
        super.onResume()
        renderStatus()
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
    }

    private fun showPage(index: Int) {
        pageHome.visibility = if (index == 0) View.VISIBLE else View.GONE
        pageSuperuser.visibility = if (index == 1) View.VISIBLE else View.GONE
        pageModules.visibility = if (index == 2) View.VISIBLE else View.GONE
        val ids = intArrayOf(R.id.nav_home, R.id.nav_superuser, R.id.nav_modules)
        ids.forEachIndexed { i, id ->
            findViewById<TextView>(id).setTextColor(getColor(if (i == index) R.color.primary else R.color.text_secondary))
        }
    }

    private fun renderStatus() {
        val available = NativeBridge.isKernelAvailable()
        val version = if (available) NativeBridge.getVersion() else 0
        val features = FeatureFlags(if (available) NativeBridge.getFeatures() else 0)

        statusValue.text = if (available) {
            val v = "%d.%d.%d (%s)".format(
                (version ushr 16) and 0xff,
                (version ushr 8) and 0xff,
                version and 0xff,
                if (NativeBridge.isKernelModule()) "LKM" else "built-in"
            )
            v
        } else {
            getString(R.string.status_unknown)
        }
        statusIcon.setImageResource(if (available) R.drawable.ic_shield_on else R.drawable.ic_shield_off)

        featureProfile.text = yesNo(features.has(FeatureFlags.PROFILE))
        featureDenylist.text = yesNo(features.has(FeatureFlags.DENYLIST))
        featureSepolicy.text = yesNo(features.has(FeatureFlags.SEPOLICY))
        featureSafemode.text = if (available && NativeBridge.isSafeMode()) "已触发" else "未触发"
        moduleState.text = getString(R.string.module_hint)
    }

    private fun checkRootInBackground() {
        executor.execute {
            val result = RootDetector.detect()
            runOnUiThread {
                rootState.text = if (result.available) {
                    getString(R.string.root_detected, result.solution.label, result.suPath)
                } else {
                    getString(R.string.root_absent)
                }
                hotStartButton.isEnabled = result.available
                hotStartResult.text = if (result.available) {
                    getString(R.string.hotstart_ready)
                } else {
                    getString(R.string.hotstart_need_root)
                }
            }
        }
    }

    private fun onHotStartClicked() {
        hotStartButton.isEnabled = false
        hotStartResult.text = getString(R.string.hotstart_running)
        executor.execute {
            val outcome = HotStart.execute(this)
            runOnUiThread {
                when (outcome) {
                    is HotStart.Outcome.Ok -> {
                        hotStartResult.text = getString(R.string.hotstart_ok, outcome.detail)
                        renderStatus()
                        loadSuperuserList()
                    }
                    is HotStart.Outcome.Failed ->
                        hotStartResult.text = getString(R.string.hotstart_fail, outcome.reason)
                }
                hotStartButton.isEnabled = true
            }
        }
    }

    private fun loadSuperuserList() {
        executor.execute {
            val uids = NativeBridge.allowList()
            val apps = PackageScanner.scan(this, uids)
            runOnUiThread {
                adapter.replaceAll(apps)
                emptyHint.visibility = if (apps.isEmpty()) View.VISIBLE else View.GONE
            }
        }
    }

    private fun yesNo(value: Boolean): String = if (value) "支持" else "不支持"
}
