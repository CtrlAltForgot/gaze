# Reuse Synopti's installed matching and audio tools in an isolated service.
ARG SYNOPTI_IMAGE=synoptibot:v3
FROM ${SYNOPTI_IMAGE}
COPY --chown=node:node . /gaze/server
WORKDIR /gaze/server
CMD ["node", "index.js"]
