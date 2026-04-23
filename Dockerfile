FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    automake \
    autoconf \
    libtool \
    pkg-config \
    wget \
    ca-certificates \
    zlib1g-dev \
    libcurl4-gnutls-dev \
    liblua5.4-dev \
    libsqlite3-dev \
    libreadline-dev \
    libicu-dev \
    gettext \
    python3 \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN wget -q "https://downloads.sourceforge.net/project/freeciv/Freeciv%203.2/3.2.4/freeciv-3.2.4.tar.xz" -O /tmp/freeciv.tar.xz && \
    cd /tmp && tar xf freeciv.tar.xz

RUN cd /tmp/freeciv-3.2.4 && \
    ./configure \
      --prefix=/usr/local \
      --enable-server \
      --enable-fcdb=sqlite3 \
      --enable-aimodules=no \
      --disable-client \
      --disable-fcmp \
      --disable-ruledit \
      --disable-nls \
      --disable-sdl-mixer \
      --without-qt \
      --without-qt6 \
      --without-gtk3 \
      --without-gtk4 \
      --without-sdl2 \
      --without-sdl3 \
    && make -j$(nproc) \
    && make install

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl3-gnutls \
    liblua5.4-0 \
    libsqlite3-0 \
    libreadline8 \
    libicu72 \
    lua-sql-sqlite3 \
    sqlite3 \
    curl \
    ca-certificates \
    zlib1g \
    busybox-static \
    jq \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/local/share/freeciv/ /usr/local/share/freeciv/
COPY --from=builder /usr/local/etc/freeciv/ /usr/local/etc/freeciv/

RUN ldconfig && \
    useradd -m -s /bin/bash freeciv && \
    mkdir -p /data/saves /opt/freeciv /opt/freeciv/www && \
    chown -R freeciv:freeciv /data/saves /opt/freeciv

COPY fcdb.conf /etc/freeciv/fcdb.conf
COPY database.lua /usr/local/etc/freeciv/database.lua
COPY longturn.serv /etc/freeciv/longturn.serv
COPY turn_notify.lua /opt/freeciv/turn_notify.lua
COPY turn_notify.sh /opt/freeciv/turn_notify.sh
COPY turn_reminder.sh /opt/freeciv/turn_reminder.sh
COPY email_enabled.settings /opt/freeciv/email_enabled.settings
COPY start.sh /opt/freeciv/start.sh
COPY generate_status_json.sh /opt/freeciv/generate_status_json.sh
COPY generate_gazette.sh /opt/freeciv/generate_gazette.sh
COPY lib_diplomacy.sh /opt/freeciv/lib_diplomacy.sh
COPY generate_nations.sh /opt/freeciv/generate_nations.sh
COPY www/index.html /opt/freeciv/www/index.html
COPY www/changelog.html /opt/freeciv/www/changelog.html
COPY www/editor.html /opt/freeciv/www/editor.html
COPY www/admin.html /opt/freeciv/www/admin.html
COPY www/dashboard.html /opt/freeciv/www/dashboard.html
COPY www/login.html /opt/freeciv/www/login.html
COPY respond_to_editor.sh /opt/freeciv/respond_to_editor.sh
COPY generate_dashboard.sh /opt/freeciv/generate_dashboard.sh
COPY www/cgi-bin/ /opt/freeciv/www/cgi-bin/
COPY crontab /etc/crontabs/freeciv
RUN chmod +x /opt/freeciv/turn_notify.sh /opt/freeciv/turn_reminder.sh /opt/freeciv/start.sh /opt/freeciv/generate_status_json.sh /opt/freeciv/generate_gazette.sh /opt/freeciv/generate_nations.sh /opt/freeciv/respond_to_editor.sh /opt/freeciv/generate_dashboard.sh /opt/freeciv/www/cgi-bin/*

EXPOSE 5556 8080

COPY entrypoint.sh /opt/freeciv/entrypoint.sh
RUN chmod +x /opt/freeciv/entrypoint.sh

CMD ["/opt/freeciv/entrypoint.sh"]
