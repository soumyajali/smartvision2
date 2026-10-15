from html import escape

import streamlit as st


def icon_html(name: str) -> str:
    """Material Symbols icon (the icon font bundled with Streamlit)."""
    return f"<span class='sv-icon' aria-hidden='true'>{escape(name)}</span>"


def status_pill(label: str, tone: str = "success"):
    label = (label or "").strip()
    if not label:
        return
    st.markdown(
        f"""
        <div class="status-pill status-{tone}">{label}</div>
        """,
        unsafe_allow_html=True,
    )


def page_header(title: str, subtitle: str = "", status: str = "", icon: str = "visibility"):
    st.markdown(
        f"""
        <div class="page-header">
          <div class="page-header-icon">{icon_html(icon)}</div>
          <div class="page-header-copy">
            <div class="page-kicker">SmartVision</div>
            <h2>{title}</h2>
            <p>{subtitle}</p>
          </div>
          {f'<div class="status-pill status-success">{status}</div>' if status else ''}
        </div>
        """,
        unsafe_allow_html=True,
    )


def metric_card(title: str, value: str, icon: str = "monitoring", accent: str = "cyan"):
    st.markdown(
        f"""
        <div class="metric-card metric-{accent}">
          <div class="metric-icon">{icon_html(icon)}</div>
          <div class="metric-copy">
            <div class="metric-label">{title}</div>
            <div class="metric-value">{value}</div>
          </div>
        </div>
        """,
        unsafe_allow_html=True,
    )


def empty_state(message: str, icon: str = "inbox"):
    st.markdown(
        f"""
        <div class="empty-state">
          <div class="empty-icon">{icon_html(icon)}</div>
          <div class="empty-message">{message}</div>
        </div>
        """,
        unsafe_allow_html=True,
    )


def object_chip(label: str, confidence: float = 0.0, variant: str = "primary"):
    percentage = int(max(0, min(100, confidence * 100))) if confidence else 0
    st.markdown(
        f"""
        <div class="object-chip object-{variant}">
          <span>{label}</span>
          <div class="chip-progress"><span style="width:{percentage}%"></span></div>
          <strong>{percentage}%</strong>
        </div>
        """,
        unsafe_allow_html=True,
    )
