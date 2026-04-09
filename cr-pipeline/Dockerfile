# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/powershell:latest

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    APP_HOME=/app \
    PORT=8090 \
    PIPELINE_DATA_DIR=/data/jobs \
    DEBIAN_FRONTEND=noninteractive

WORKDIR ${APP_HOME}

# Installer Python + libgdiplus
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip \
    libgdiplus \
 && rm -rf /var/lib/apt/lists/*



COPY requirements.txt ${APP_HOME}/requirements.txt
RUN pip3 install --no-cache-dir -r requirements.txt



# Installer ImportExcel via PowerShell (dans pwsh)
RUN pwsh -NoLogo -NoProfile -Command "& { \
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
  Install-PackageProvider -Name NuGet -Force; \
  Install-Module ImportExcel -Scope AllUsers -Force -AllowClobber; \
}"

COPY app ${APP_HOME}/app
COPY pipeline /pipeline

RUN mkdir -p ${PIPELINE_DATA_DIR}

EXPOSE ${PORT}
CMD ["python3", "-m", "app.app"]
