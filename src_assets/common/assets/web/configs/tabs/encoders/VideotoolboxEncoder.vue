<script setup>
import { ref } from 'vue'
import Checkbox from "../../../Checkbox.vue";

const props = defineProps({
  platform: String,
  config: Object,
})

const config = ref(props.config)
</script>

<template>
  <div id="videotoolbox-encoder" class="config-page">
    <!-- Presets -->
    <div class="mb-3">
      <label for="vt_coder" class="form-label">{{ $t('config.vt_coder') }}</label>
      <select id="vt_coder" class="form-select" v-model="config.vt_coder">
        <option value="auto">{{ $t('_common.auto') }}</option>
        <option value="cabac">{{ $t('config.coder_cabac') }}</option>
        <option value="cavlc">{{ $t('config.coder_cavlc') }}</option>
      </select>
    </div>
    <Checkbox class="mb-3"
              id="vt_realtime"
              desc=""
              locale-prefix="config"
              v-model="config.vt_realtime"
              default="true"
    ></Checkbox>
    <div class="mb-3">
      <label for="capture_dynamic_range_macos" class="form-label">{{ $t('config.capture_dynamic_range_macos') }}</label>
      <select id="capture_dynamic_range_macos" class="form-select" v-model="config.capture_dynamic_range_macos">
        <option value="hdr_canonical">{{ $t('config.capture_dynamic_range_hdr_canonical') }}</option>
        <option value="hdr_local">{{ $t('config.capture_dynamic_range_hdr_local') }}</option>
        <option value="sdr">{{ $t('config.capture_dynamic_range_sdr') }}</option>
      </select>
      <div class="form-text">{{ $t('config.capture_dynamic_range_macos_desc') }}</div>
    </div>
    <div class="mb-3">
      <label for="hdr_max_luminance_macos" class="form-label">{{ $t('config.hdr_max_luminance_macos') }}</label>
      <input type="number" class="form-control" id="hdr_max_luminance_macos" min="-1" max="10000" step="1" v-model.number="config.hdr_max_luminance_macos" placeholder="-1" />
      <div class="form-text">{{ $t('config.hdr_max_luminance_macos_desc') }}</div>
    </div>
  </div>
</template>
