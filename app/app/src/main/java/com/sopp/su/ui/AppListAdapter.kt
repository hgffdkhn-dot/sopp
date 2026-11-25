package com.sopp.su.ui

import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.ImageView
import android.widget.Switch
import android.widget.TextView
import com.sopp.su.R
import com.sopp.su.bridge.NativeBridge
import com.sopp.su.data.AppInfo

/** Backs the superuser list. Switch changes are pushed into the kernel. */
class AppListAdapter(context: Context) : BaseAdapter() {

    private val inflater = LayoutInflater.from(context)
    private val apps = mutableListOf<AppInfo>()

    fun replaceAll(items: List<AppInfo>) {
        apps.clear()
        apps.addAll(items)
        notifyDataSetChanged()
    }

    override fun getCount(): Int = apps.size

    override fun getItem(position: Int): AppInfo = apps[position]

    override fun getItemId(position: Int): Long = position.toLong()

    override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
        val row: View
        val holder: ViewHolder
        if (convertView == null) {
            row = inflater.inflate(R.layout.item_app, parent, false)
            holder = ViewHolder(row)
            row.tag = holder
        } else {
            row = convertView
            holder = row.tag as ViewHolder
        }

        val app = apps[position]
        holder.icon.setImageDrawable(app.icon)
        holder.label.text = app.label
        holder.packageName.text = app.packageName

        holder.access.setOnCheckedChangeListener(null)
        holder.access.isChecked = app.granted
        holder.access.setOnCheckedChangeListener { button, checked ->
            if (NativeBridge.setAppAccess(app.uid, checked, app.packageName)) {
                app.granted = checked
            } else {
                button.isChecked = !checked
            }
        }
        return row
    }

    private class ViewHolder(view: View) {
        val icon: ImageView = view.findViewById(R.id.app_icon)
        val label: TextView = view.findViewById(R.id.app_label)
        val packageName: TextView = view.findViewById(R.id.app_package)
        val access: Switch = view.findViewById(R.id.app_access)
    }
}
